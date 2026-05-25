#import "BLEBridge.h"
#import <Foundation/Foundation.h>
#include <libdivecomputer/ble.h>
#include <libdivecomputer/ioctl.h>

static id<CoreBluetoothManagerProtocol> bleManager = nil;

void initializeBLEManager(void) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    bleManager = [CoreBluetoothManagerClass shared];
}

ble_object_t* createBLEObject(void) {
    ble_object_t* obj = malloc(sizeof(ble_object_t));
    obj->manager = (__bridge void *)bleManager;
    return obj;
}

void freeBLEObject(ble_object_t* obj) {
    if (obj) {
        free(obj);
    }
}

bool connectToBLEDevice(ble_object_t *io, const char *deviceAddress) {
    if (!io || !deviceAddress) {
        NSLog(@"Invalid parameters passed to connectToBLEDevice");
        return false;
    }
    
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    NSString *address = [NSString stringWithUTF8String:deviceAddress];
    
    bool success = [manager connectToDevice:address];
    if (!success) {
        NSLog(@"Failed to connect to device");
        return false;
    }
    
    // Wait for connection to complete by checking peripheral ready state
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0]; // 10 second timeout
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        // Check if peripheral is ready using protocol method
        if ([manager getPeripheralReadyState]) {
            NSLog(@"Peripheral is ready for communication");
            break;
        }
        // Small sleep to avoid busy-waiting
        [NSThread sleepForTimeInterval:0.1];
    }
    
    // Final check if we're actually ready
    if (![manager getPeripheralReadyState]) {
        NSLog(@"Timeout waiting for peripheral to be ready");
        [manager close];
        return false;
    }

    success = [manager discoverServices];
    if (!success) {
        NSLog(@"Service discovery failed");
        [manager close];
        return false;
    }

    success = [manager enableNotifications];
    if (!success) {
        NSLog(@"Failed to enable notifications");
        [manager close];
        return false;
    }
    
    return true;
}

bool discoverServices(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    return [manager discoverServices];
}

bool enableNotifications(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    return [manager enableNotifications];
}

dc_status_t ble_set_timeout(ble_object_t *io, int timeout) {
    // Forward the backend's requested read timeout to the BLE manager. libdivecomputer
    // backends (e.g. uwatec_smart) set this to 5000ms; ignoring it left reads capped at a
    // hardcoded 3s, causing DC_STATUS_IO when a device paused mid-download.
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    [manager setReadTimeout:timeout];
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_ioctl(ble_object_t *io, unsigned int request, void *data, size_t size) {
    if (!io) {
        return DC_STATUS_INVALIDARGS;
    }

    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];

    switch (request) {
    case DC_IOCTL_BLE_CHARACTERISTIC_READ: {
        // Request layout: [16-byte big-endian UUID][N-byte read buffer], size = 16 + N.
        // libdivecomputer (e.g. cressi_goa) reads serial/model/firmware this way and expects
        // exactly N bytes copied back into the buffer in place, after the UUID prefix.
        if (!data || size < sizeof(dc_ble_uuid_t)) {
            return DC_STATUS_INVALIDARGS;
        }

        char uuidstr[DC_BLE_UUID_SIZE] = {0};
        if (dc_ble_uuid2str((const unsigned char *)data, uuidstr, sizeof(uuidstr)) == NULL) {
            return DC_STATUS_INVALIDARGS;
        }

        size_t want = size - sizeof(dc_ble_uuid_t);
        NSString *uuid = [NSString stringWithUTF8String:uuidstr];
        NSData *value = [manager readCharacteristicByUUID:uuid timeout:5.0];
        if (!value || value.length < want) {
            return DC_STATUS_IO;
        }

        memcpy((unsigned char *)data + sizeof(dc_ble_uuid_t), value.bytes, want);
        return DC_STATUS_SUCCESS;
    }

    case DC_IOCTL_BLE_GET_NAME:
        return DC_STATUS_UNSUPPORTED;

    case DC_IOCTL_BLE_GET_PINCODE: {
        if (!data || size == 0) return DC_STATUS_INVALIDARGS;
        NSString *pin = [manager consumePendingPincode];
        if (pin == nil) {
            NSLog(@"ble_ioctl: GET_PINCODE requested but no PIN pending");
            return DC_STATUS_UNSUPPORTED;
        }
        const char *utf8 = [pin UTF8String];
        size_t len = strlen(utf8);
        if (len + 1 > size) return DC_STATUS_INVALIDARGS;
        memcpy(data, utf8, len);
        ((char *)data)[len] = '\0';
        return DC_STATUS_SUCCESS;
    }

    case DC_IOCTL_BLE_GET_ACCESSCODE: {
        if (!data || size == 0) return DC_STATUS_INVALIDARGS;
        NSData *code = [manager getStoredAccessCode];
        if (code == nil) {
            // DC_STATUS_UNSUPPORTED = "no code stored"; caller falls back to PIN auth.
            return DC_STATUS_UNSUPPORTED;
        }
        if (code.length != size) {
            NSLog(@"ble_ioctl: stored access code size mismatch (%lu vs %zu)",
                  (unsigned long)code.length, size);
            return DC_STATUS_UNSUPPORTED;
        }
        memcpy(data, code.bytes, size);
        return DC_STATUS_SUCCESS;
    }

    case DC_IOCTL_BLE_SET_ACCESSCODE: {
        if (!data || size == 0) return DC_STATUS_INVALIDARGS;
        NSData *code = [NSData dataWithBytes:data length:size];
        [manager storeAccessCode:code];
        return DC_STATUS_SUCCESS;
    }

    default:
        return DC_STATUS_UNSUPPORTED;
    }
}

dc_status_t ble_sleep(ble_object_t *io, unsigned int milliseconds) {
    [NSThread sleepForTimeInterval:milliseconds / 1000.0];
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_read(ble_object_t *io, void *buffer, size_t requested, size_t *actual)
{
    if (!io || !buffer || !actual) {
        return DC_STATUS_INVALIDARGS;
    }

    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];

    // Return one BLE packet at a time to preserve packet boundaries for SLIP framing
    NSData *partialData = [manager readDataPartial:(int)requested];

    if (!partialData || partialData.length == 0) {
        *actual = 0;
        return DC_STATUS_IO;
    }
    memcpy(buffer, partialData.bytes, partialData.length);
    *actual = partialData.length;
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_write(ble_object_t *io, const void *data, size_t size, size_t *actual) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    NSData *nsData = [NSData dataWithBytes:data length:size];
    
    if ([manager writeData:nsData]) {
        *actual = size;
        return DC_STATUS_SUCCESS;
    } else {
        *actual = 0;
        return DC_STATUS_IO;
    }
}

dc_status_t ble_purge(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    [manager purgeReceivedData];
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_close(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    [manager close];
    return DC_STATUS_SUCCESS;
}
