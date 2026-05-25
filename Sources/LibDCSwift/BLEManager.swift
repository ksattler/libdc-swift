import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
import LibDCBridge.CoreBluetoothManagerProtocol
import Combine

/// Represents a BLE serial service with its identifying information
@objc(SerialService)
class SerialService: NSObject {
    @objc let uuid: String
    @objc let vendor: String
    @objc let product: String
    
    @objc init(uuid: String, vendor: String, product: String) {
        self.uuid = uuid
        self.vendor = vendor
        self.product = product
        super.init()
    }
}

/// Extension to check if a CBUUID is a standard Bluetooth service UUID
extension CBUUID {
    var isStandardBluetooth: Bool {
        return self.data.count == 2
    }
}

/// Central manager for handling BLE communications with dive computers.
/// Manages device discovery, connection, and data transfer with BLE dive computers.
@objc(CoreBluetoothManager)
public class CoreBluetoothManager: NSObject, CoreBluetoothManagerProtocol, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // MARK: - Singleton
    private static let sharedInstance = CoreBluetoothManager()
    
    @objc public static func shared() -> Any! {
        return sharedInstance
    }
    
    public static var sharedManager: CoreBluetoothManager {
        return sharedInstance
    }
    
    // MARK: - Published Properties
    @Published public var centralManager: CBCentralManager! // Core Bluetooth central manager instance
    @Published public var peripheral: CBPeripheral? // Currently selected peripheral device
    @Published public var discoveredPeripherals: [CBPeripheral] = [] // List of discovered BLE peripherals
    @Published public var isPeripheralReady = false // Indicates if peripheral is ready for communication
    @Published @objc dynamic public var connectedDevice: CBPeripheral? // Currently connected peripheral device
    @Published public var isScanning = false // Indicates if currently scanning for devices
    @Published public var isRetrievingLogs = false { // Indicates if currently retrieving dive logs
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var currentRetrievalDevice: CBPeripheral? { // Device currently being used for log retrieval
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var isDisconnecting = false // Indicates if currently disconnecting from device
    @Published public var isBluetoothReady = false // Indicates if Bluetooth is ready for use
    @Published public var isConnecting = false // Indicates if a connection attempt is in progress (prevents auto-reconnect)
    @Published private var deviceDataPtrChanged = false

    // MARK: - Private Properties
    @objc private var timeout: Int = -1 // default to no timeout
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    /// u-blox / HW SPS credits flow-control channel. For services that use a
    /// credits-based BLE Serial-Port-Service (e.g. OSTC 4/5 via 2456e1b9-...
    /// "u-connectXpress SPS", UBX-16011192) the device will not send any data
    /// until the central writes an initial credit count to this characteristic.
    private var creditsCharacteristic: CBCharacteristic?
    private static let creditBatch: UInt8 = 0x40  // 64 packets per top-up
    private static let creditLowWater: Int = 32   // refill once budget hits this
    /// Credits still owed to us by the peer: how many more notifications the
    /// device may send before it must wait for us to grant more.
    private var peerCreditBudget: Int = 0
    private var receivedData: Data = Data()
    /// FIFO of complete BLE notifications. Each entry is exactly one
    /// `peripheral(_:didUpdateValueFor:)` value. Used by `readDataPartial`
    /// to preserve per-notification framing required by packet-oriented
    /// protocols like Pelagic i330R.
    private var receivedPackets: [Data] = []
    private let queue = DispatchQueue(label: "com.blemanager.queue")
    private let dataAvailableSemaphore = DispatchSemaphore(value: 0) // Signals when new data arrives
    private let writeReadySemaphore = DispatchSemaphore(value: 0) // Signals when peripheral can accept a no-response write
    private let writeConfirmSemaphore = DispatchSemaphore(value: 0) // Signals when a with-response write completes
    private var lastWriteError: Error? // Result of the most recent with-response write
    private let frameMarker: UInt8 = 0x7E
    private var _deviceDataPtr: UnsafeMutablePointer<device_data_t>?
    private var connectionCompletion: ((Bool) -> Void)?
    private var totalBytesReceived: Int = 0
    private var lastDataReceived: Date?
    private var averageTransferRate: Double = 0
    private var preferredService: CBService?
    private var pendingOperations: [() -> Void] = []
    /// All characteristics of the preferred service, keyed by lowercased UUID string.
    /// Used by `readCharacteristic(byUUID:timeout:)` to service BLE characteristic-read ioctls
    /// (e.g. Cressi reads serial/model/firmware via DC_IOCTL_BLE_CHARACTERISTIC_READ).
    private var characteristicsByUUID: [String: CBCharacteristic] = [:]
    /// Result slot for an in-flight explicit characteristic read; accessed under `queue`.
    private var ioctlReadValue: Data?
    /// Lowercased UUID of the characteristic an explicit read is currently awaiting; accessed under `queue`.
    private var ioctlReadCharUUID: String?
    /// Nordic UART serial service. Cressi advertises both this and its own vendor service,
    /// but libdivecomputer requires the vendor service, so this must never win preferred-service selection.
    private let nordicUARTServiceUUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
    
    // MARK: - Public Properties
    public var openedDeviceDataPtr: UnsafeMutablePointer<device_data_t>? { // Public access to device data pointer with change notification
        get {
            _deviceDataPtr
        }
        set {
            objectWillChange.send()
            _deviceDataPtr = newValue
        }
    }
    
    /// Checks if there is a valid device data pointer
    /// - Returns: True if device data pointer exists
    public func hasValidDeviceDataPtr() -> Bool {
        return openedDeviceDataPtr != nil
    }

    // MARK: - Pelagic i330R/DSX Authentication
    /// True while the libdivecomputer protocol thread is blocked waiting for
    /// the user to enter a PIN. Observed by the UI to show a prompt.
    @Published public var isWaitingForPincode = false

    private var _pendingPincode: String?
    private let authLock = NSLock()
    private let pincodeSemaphore = DispatchSemaphore(value: 0)

    /// UUID of the device the libdivecomputer C protocol is currently opening.
    /// Set by `DeviceConfiguration.openBLEDevice` before the C open call so
    /// the BLE bridge can look up the matching stored access code.
    public var connectingDeviceUUID: String?

    /// Called from the UI after the user enters a PIN. Wakes up the protocol
    /// thread that is blocked inside `consumePendingPincode`.
    public func submitPincode(_ pin: String) {
        authLock.lock()
        _pendingPincode = pin
        authLock.unlock()
        DispatchQueue.main.async { self.isWaitingForPincode = false }
        pincodeSemaphore.signal()
    }

    /// Called from the UI if the user cancels the PIN prompt.
    public func cancelPincode() {
        authLock.lock()
        _pendingPincode = nil
        authLock.unlock()
        DispatchQueue.main.async { self.isWaitingForPincode = false }
        pincodeSemaphore.signal()
    }

    /// Called from the BLE bridge (background protocol thread) when the C
    /// code issues `DC_IOCTL_BLE_GET_PINCODE`. Blocks until the user submits
    /// a PIN via the UI. Returns nil if the user cancels or the wait times out.
    @objc public func consumePendingPincode() -> String? {
        // The protocol may invoke this in a retry loop with the same connection.
        // Each call requires a fresh user interaction.
        DispatchQueue.main.async { self.isWaitingForPincode = true }

        // Wait up to 2 minutes for user input
        let result = pincodeSemaphore.wait(timeout: .now() + 120)
        if result == .timedOut {
            DispatchQueue.main.async { self.isWaitingForPincode = false }
            return nil
        }

        authLock.lock()
        let pin = _pendingPincode
        _pendingPincode = nil
        authLock.unlock()
        return pin
    }

    @objc public func getStoredAccessCode() -> Data? {
        guard let uuid = connectingDeviceUUID else { return nil }
        return AccessCodeStorage.shared.getAccessCode(uuid: uuid)
    }

    @objc public func storeAccessCode(_ data: Data) {
        guard let uuid = connectingDeviceUUID else { return }
        AccessCodeStorage.shared.setAccessCode(uuid: uuid, code: data)
    }
    
    // MARK: - Serial Services
    /// Known BLE serial services for supported dive computers
    @objc private let knownSerialServices: [SerialService] = [
        SerialService(uuid: "0000fefb-0000-1000-8000-00805f9b34fb", vendor: "Heinrichs-Weikamp", product: "Telit/Stollmann"),
        SerialService(uuid: "2456e1b9-26e2-8f83-e744-f34f01e9d701", vendor: "Heinrichs-Weikamp", product: "U-Blox"),
        SerialService(uuid: "544e326b-5b72-c6b0-1c46-41c1bc448118", vendor: "Mares", product: "BlueLink Pro"),
        SerialService(uuid: "6e400001-b5a3-f393-e0a9-e50e24dcca9e", vendor: "Nordic Semi", product: "UART"),
        SerialService(uuid: "6e400001-b5a3-f393-e0a9-e50e24dc10b8", vendor: "Cressi", product: "Goa"),
        SerialService(uuid: "98ae7120-e62e-11e3-badd-0002a5d5c51b", vendor: "Suunto", product: "EON Steel/Core"),
        SerialService(uuid: "cb3c4555-d670-4670-bc20-b61dbc851e9a", vendor: "Pelagic", product: "i770R/i200C"),
        SerialService(uuid: "ca7b0001-f785-4c38-b599-c7c5fbadb034", vendor: "Pelagic", product: "i330R/DSX"),
        SerialService(uuid: "fdcdeaaa-295d-470e-bf15-04217b7aa0a0", vendor: "ScubaPro", product: "G2/G3"),
        SerialService(uuid: "fe25c237-0ece-443c-b0aa-e02033e7029d", vendor: "Shearwater", product: "Perdix/Teric"),
        SerialService(uuid: "0000fcef-0000-1000-8000-00805f9b34fb", vendor: "Divesoft", product: "Freedom"),
        SerialService(uuid: "00000001-8c3b-4f2c-a59e-8c08224f3253", vendor: "Halcyon", product: "Symbios"),
        SerialService(uuid: "84968ffe-d26d-478a-b953-5010bcf58bca", vendor: "Seac", product: "Screen")
    ]
    
    /// Service UUIDs to exclude from discovery
    private let excludedServices: Set<String> = [
        "00001530-1212-efde-1523-785feabcd123", // Nordic Upgrade
        "9e5d1e47-5c13-43a0-8635-82ad38a1386f", // Broadcom Upgrade #1
        "a86abc2d-d44c-442e-99f7-80059a873e36"  // Broadcom Upgrade #2
    ]
    
    // MARK: - Initialization
    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Service Discovery
    @objc(getPeripheralReadyState)
    public func getPeripheralReadyState() -> Bool {
        return self.isPeripheralReady
    }
    
    @objc(discoverServices)
    public func discoverServices() -> Bool {
        guard let peripheral = self.peripheral else {
            logError("No peripheral available for service discovery")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state: \(peripheral.state.rawValue)")
            return false
        }
        
        peripheral.discoverServices(nil)
        
        // Wait for characteristics with timeout
        let timeout = Date(timeIntervalSinceNow: 5.0)
        while writeCharacteristic == nil || notifyCharacteristic == nil {
            if Date() > timeout {
                logError("Timeout waiting for service discovery")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        
        return writeCharacteristic != nil && notifyCharacteristic != nil
    }
    
    @objc(enableNotifications)
    public func enableNotifications() -> Bool {
        guard let notifyCharacteristic = self.notifyCharacteristic,
              let peripheral = self.peripheral else {
            logError("Missing characteristic or peripheral for notifications")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state for notifications: \(peripheral.state.rawValue)")
            return false
        }
        
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
        
        // Wait for notifications to be enabled with timeout
        let timeout = Date(timeIntervalSinceNow: 5.0)
        while !notifyCharacteristic.isNotifying {
            if Date() > timeout {
                logError("Timeout waiting for notifications to enable")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        
        return notifyCharacteristic.isNotifying
    }

    /// Discards every buffered BLE notification. Used by `ble_purge` from the
    /// libdivecomputer bridge after a corrupt-profile recovery to make sure
    /// stale junk bytes from the previous response don't bleed into the next
    /// command's echo read.
    @objc public func purgeReceivedData() {
        queue.sync {
            receivedData.removeAll()
            receivedPackets.removeAll()
        }
    }
    
    // MARK: - Data Handling
    private func findNextCompleteFrame() -> Data? {
        var frameToReturn: Data? = nil
        
        queue.sync {
            guard let startIndex = receivedData.firstIndex(of: frameMarker) else {
                return
            }
            
            let afterStart = receivedData.index(after: startIndex)
            guard afterStart < receivedData.count,
                  let endIndex = receivedData[afterStart...].firstIndex(of: frameMarker) else {
                return
            }
            
            let frameEndIndex = receivedData.index(after: endIndex)
            let frame = receivedData[startIndex..<frameEndIndex]
            
            receivedData.removeSubrange(startIndex..<frameEndIndex)
            frameToReturn = Data(frame)
        }
        
        return frameToReturn
    }
    
    @objc public func write(_ data: Data!) -> Bool {
        guard let peripheral = self.peripheral,
              let characteristic = self.writeCharacteristic else { return false }
        // Choose the write type from the characteristic's properties rather than always using
        // .withoutResponse. A characteristic that only supports Write (with response) silently
        // drops .withoutResponse writes on CoreBluetooth. Prefer .withoutResponse when available
        // (preserves behavior for devices that work today), else fall back to .withResponse.
        // Matches Subsurface (qt-ble.cpp) and submersion (BleIoStream.swift).
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        // Per-write deadline from the backend-requested timeout (falls back to 3s).
        let timeoutMs = self.timeout > 0 ? self.timeout : 3000

        if writeType == .withoutResponse {
            // Don't overrun CoreBluetooth's transmit queue: wait until it can accept a
            // no-response write, otherwise the write is silently dropped during bursts.
            if !peripheral.canSendWriteWithoutResponse {
                drainSemaphore(writeReadySemaphore)
                if writeReadySemaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
                    logWarning("Write blocked waiting for canSendWriteWithoutResponse")
                    return false
                }
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            return true
        } else {
            // With-response write: wait for the didWriteValueFor confirmation.
            drainSemaphore(writeConfirmSemaphore)
            lastWriteError = nil
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            if writeConfirmSemaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
                logWarning("Write withResponse timed out")
                return false
            }
            if let error = lastWriteError {
                logError("Write withResponse failed: \(error.localizedDescription)")
                return false
            }
            return true
        }
    }

    /// Drains any pending signals from a semaphore so the next wait reflects only new events.
    private func drainSemaphore(_ semaphore: DispatchSemaphore) {
        while semaphore.wait(timeout: .now()) == .success { }
    }
    
    /// Sets the per-read timeout (milliseconds) requested by the libdivecomputer backend.
    /// A non-positive value means "no timeout was set"; `readDataPartial` then uses its default.
    @objc public func setReadTimeout(_ milliseconds: Int32) {
        self.timeout = Int(milliseconds)
    }

    @objc public func readDataPartial(_ requested: Int32) -> Data? {
        let requestedInt = Int(requested)
        let startTime = Date()
        // Honor the timeout the backend requested via dc_iostream_set_timeout; fall back to 3s
        // when unset (timeout < 0). Previously this was hardcoded to 3s, ignoring the backend.
        let timeout: TimeInterval = self.timeout > 0 ? Double(self.timeout) / 1000.0 : 3.0

        while Date().timeIntervalSince(startTime) < timeout {
            var outData: Data?

            queue.sync {
                // Prefer the per-notification queue so packet boundaries are
                // preserved for protocols that expect one BLE notification per
                // read (e.g. Pelagic i330R). If the caller's requested size is
                // smaller than the head packet, return what fits and push the
                // remainder back to the front for the next read.
                if !receivedPackets.isEmpty {
                    var head = receivedPackets.removeFirst()
                    if head.count <= requestedInt {
                        outData = head
                        // Keep flat buffer consistent
                        let drop = min(head.count, receivedData.count)
                        receivedData.removeSubrange(0..<drop)
                    } else {
                        let returned = head.prefix(requestedInt)
                        let remainder = head.suffix(from: requestedInt)
                        receivedPackets.insert(Data(remainder), at: 0)
                        outData = Data(returned)
                        let drop = min(returned.count, receivedData.count)
                        receivedData.removeSubrange(0..<drop)
                    }
                }
            }

            if let data = outData {
                return data
            }

            // Wait for data - use semaphore with short timeout, fall back to brief sleep
            let result = dataAvailableSemaphore.wait(timeout: .now() + .milliseconds(50))
            if result == .timedOut {
                // Brief sleep as fallback to avoid tight spin loop
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        let pktCount = queue.sync { receivedPackets.count }
        logWarning("readDataPartial: timed out waiting for \(requestedInt) bytes; queue=\(pktCount) creditBudget=\(peerCreditBudget)")
        return nil
    }
    
    // MARK: - Device Management
    @objc public func close(clearDevicePtr: Bool = false) {
        // Signal that teardown is in progress on main before blocking C calls start.
        DispatchQueue.main.async {
            self.isDisconnecting = true
            self.isPeripheralReady = false
            self.connectedDevice = nil
        }

        queue.sync {
            if !receivedData.isEmpty {
                receivedData.removeAll()
            }
            characteristicsByUUID.removeAll()
            ioctlReadValue = nil
            ioctlReadCharUUID = nil
            receivedPackets.removeAll()
        }

        // Drain and signal semaphore to unblock any waiting reads and clear stale signals
        while dataAvailableSemaphore.wait(timeout: .now()) == .success {
            // Drain any accumulated signals
        }
        dataAvailableSemaphore.signal() // Signal once to unblock any waiting read

        if clearDevicePtr {
            if let devicePtr = _deviceDataPtr {
                if devicePtr.pointee.device != nil {
                    dc_device_close(devicePtr.pointee.device)
                }
                devicePtr.deallocate()
                // Bypass the setter (which calls objectWillChange.send()) because
                // we're on a background thread. Nil the ivar directly, then notify
                // the UI on main so SwiftUI sees the change without a thread warning.
                _deviceDataPtr = nil
                DispatchQueue.main.async { self.objectWillChange.send() }
            }
        }

        // CoreBluetooth calls must run on the main thread.
        DispatchQueue.main.async {
            if let peripheral = self.peripheral {
                self.writeCharacteristic = nil
                self.notifyCharacteristic = nil
                self.creditsCharacteristic = nil
                self.peripheral = nil
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isDisconnecting = false
            }
        }
    }
    
    public func startScanning(omitUnsupportedPeripherals: Bool = true) {
        centralManager.scanForPeripherals(
            withServices: omitUnsupportedPeripherals ? knownSerialServices.map { CBUUID(string: $0.uuid) } : nil,
            options: nil)
        isScanning = true
    }
    
    public func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }
    
    @objc public func connect(toDevice address: String!) -> Bool {
        guard let uuid = UUID(uuidString: address),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            return false
        }
        
        self.peripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        return true  // Return immediately, connection status will be handled by delegate
    }
    
    public func connectToStoredDevice(_ uuid: String) -> Bool {
        guard let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid) else {
            return false
        }
        
        return DeviceConfiguration.openBLEDevice(
            name: storedDevice.name,
            deviceAddress: storedDevice.uuid
        )
    }
    
    // MARK: - State Management
    public func clearRetrievalState() {
        DispatchQueue.main.async { [weak self] in
            self?.isRetrievingLogs = false
            self?.currentRetrievalDevice = nil
        }
    }
    
    public func setBackgroundMode(_ enabled: Bool) {
        if enabled {
            // Set connection parameters for background operation
            if let peripheral = peripheral {
                // For iOS/macOS, we can only ensure the connection stays alive
                // by maintaining the peripheral reference and keeping the central manager active
                
                #if os(iOS)
                // On iOS, we can request background execution time
                var backgroundTask: UIBackgroundTaskIdentifier = .invalid
                backgroundTask = UIApplication.shared.beginBackgroundTask { [backgroundTask] in
                    // Cleanup callback
                    if backgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                    }
                }
                
                // Store the task identifier for later cleanup
                currentBackgroundTask = backgroundTask
                #endif
            }
        } else {
            #if os(iOS)
            // Clean up any background tasks when disabling background mode
            if let peripheral = peripheral {
                if let task = currentBackgroundTask, task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    currentBackgroundTask = nil
                }
            }
            #endif
        }
    }

    // track background tasks
    #if os(iOS)
    private var currentBackgroundTask: UIBackgroundTaskIdentifier?
    #endif

    public func systemDisconnect(_ peripheral: CBPeripheral) {
        logInfo("Performing system-level disconnect for \(peripheral.name ?? "Unknown Device")")
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.creditsCharacteristic = nil
            self.peripheral = nil
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    public func clearDiscoveredPeripherals() {
        DispatchQueue.main.async {
            self.discoveredPeripherals.removeAll()
        }
    }
    
    public func addDiscoveredPeripheral(_ peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            if !self.discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discoveredPeripherals.append(peripheral)
            }
        }
    }

    public func queueOperation(_ operation: @escaping () -> Void) {
        if isBluetoothReady {
            operation()
        } else {
            pendingOperations.append(operation)
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logInfo("Bluetooth is powered on")
            isBluetoothReady = true
            pendingOperations.forEach { $0() }
            pendingOperations.removeAll()
        case .poweredOff:
            logWarning("Bluetooth is powered off")
            isBluetoothReady = false
        case .resetting:
            logWarning("Bluetooth is resetting")
            isBluetoothReady = false
        case .unauthorized:
            logError("Bluetooth is unauthorized")
            isBluetoothReady = false
        case .unsupported:
            logError("Bluetooth is unsupported")
            isBluetoothReady = false
        case .unknown:
            logWarning("Bluetooth state is unknown")
            isBluetoothReady = false
        @unknown default:
            logWarning("Unknown Bluetooth state")
            isBluetoothReady = false
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logInfo("Successfully connected to \(peripheral.name ?? "Unknown Device")")
        peripheral.delegate = self
        DispatchQueue.main.async {
            self.isPeripheralReady = true
            self.connectedDevice = peripheral
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logError("Failed to connect to \(peripheral.name ?? "Unknown Device"): \(error?.localizedDescription ?? "No error description")")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logInfo("Disconnected from \(peripheral.name ?? "unknown device")")
        if let error = error {
            logError("Disconnect error: \(error.localizedDescription)")
        }
        
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            
            // Don't attempt to reconnect if:
            // 1. We initiated the disconnect
            // 2. A download is currently in progress (will cause race conditions)
            // 3. A connection attempt is already in progress
            if !self.isDisconnecting && !self.isRetrievingLogs && !self.isConnecting {
                // Attempt to reconnect if this was a stored device
                if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) {
                    logInfo("Attempting to reconnect to stored device")
                    _ = DeviceConfiguration.openBLEDevice(
                        name: storedDevice.name,
                        deviceAddress: storedDevice.uuid
                    )
                }
            } else if self.isRetrievingLogs {
                logWarning("⚠️ Disconnected during download - NOT auto-reconnecting to avoid race condition")
            } else if self.isConnecting {
                logWarning("⚠️ Disconnected during connection attempt - NOT auto-reconnecting")
            }
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name != nil {
            // Add the peripheral if:
            // 1. It's a stored device
            // 2. It's a supported device
            // 3. We haven't already added it
            if DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) != nil ||
               DeviceConfiguration.fromName(peripheral.name ?? "") != nil {
                addDiscoveredPeripheral(peripheral)
            }
        }
    }

    // MARK: - CBPeripheral Methods
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logError("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else {
            logWarning("No services found")
            return
        }
        
        // Choose the preferred service across all matches before binding characteristics.
        // A vendor-specific service always wins over the generic Nordic UART service:
        // Cressi advertises both Nordic UART (…CA9E) and its own service (…10B8), and
        // libdivecomputer requires the vendor service.
        var chosen: CBService?
        var chosenIsNordic = false
        for service in services {
            if isExcludedService(service.uuid) {
                continue
            }

            if let knownService = isKnownSerialService(service.uuid) {
                let isNordic = knownService.uuid.lowercased() == nordicUARTServiceUUID
                if chosen == nil || (chosenIsNordic && !isNordic) {
                    chosen = service
                    chosenIsNordic = isNordic
                }
            }
            peripheral.discoverCharacteristics(nil, for: service)
        }

        if let chosen = chosen {
            preferredService = chosen
            writeCharacteristic = nil
            notifyCharacteristic = nil
            queue.sync { characteristicsByUUID.removeAll() }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logError("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else {
            logWarning("No characteristics found for service: \(service.uuid)")
            return
        }
        
        // When a known serial service was identified, only bind streaming characteristics
        // from that preferred service (avoids grabbing Nordic UART characteristics on Cressi,
        // which exposes both services). If no known service matched, fall back to scanning all.
        if let preferred = preferredService, service != preferred {
            return
        }

        let isUBloxSPS = service.uuid.uuidString.lowercased().hasPrefix("2456e1b9")

        for characteristic in characteristics {
            logInfo("Characteristic \(characteristic.uuid) properties: \(propertiesDescription(characteristic.properties))")
            queue.sync {
                characteristicsByUUID[characteristic.uuid.uuidString.lowercased()] = characteristic
            }

            // U-blox / HW SPS layout: FIRST write+notify = data FIFO,
            // SECOND write+notify = credits channel (must not carry protocol bytes).
            if isUBloxSPS {
                if writeCharacteristic == nil && isWriteCharacteristic(characteristic) {
                    writeCharacteristic = characteristic
                    if isReadCharacteristic(characteristic) {
                        notifyCharacteristic = characteristic
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                } else if creditsCharacteristic == nil && isWriteCharacteristic(characteristic) {
                    creditsCharacteristic = characteristic
                    if isReadCharacteristic(characteristic) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
            } else {
                if isWriteCharacteristic(characteristic) {
                    writeCharacteristic = characteristic
                }
                if isReadCharacteristic(characteristic) {
                    notifyCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    private func sendInitialCredits() {
        peerCreditBudget = 0
        grantCredits(CoreBluetoothManager.creditBatch)
    }

    private func grantCredits(_ amount: UInt8) {
        guard let peripheral = self.peripheral,
              let credits = creditsCharacteristic else { return }
        let value = Data([amount])
        let type: CBCharacteristicWriteType =
            credits.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(value, for: credits, type: type)
        peerCreditBudget += Int(amount)
        logInfo("Granted \(amount) credits to peer (budget now \(peerCreditBudget))")
    }

    private func propertiesDescription(_ props: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if props.contains(.read) { parts.append("read") }
        if props.contains(.write) { parts.append("write") }
        if props.contains(.writeWithoutResponse) { parts.append("writeWithoutResponse") }
        if props.contains(.notify) { parts.append("notify") }
        if props.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: "|")
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error receiving data: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else {
            return
        }

        // Credits-channel notifications carry flow-control bytes, not payload.
        if characteristic === creditsCharacteristic {
            if let first = data.first {
                logInfo("Received \(Int8(bitPattern: first)) credits from peer")
            }
            return
        }

        var handledAsIoctlRead = false
        queue.sync {
            // Route explicitly-requested characteristic reads (e.g. Cressi serial/model/firmware
            // via DC_IOCTL_BLE_CHARACTERISTIC_READ) to the ioctl slot instead of the data stream.
            if let want = ioctlReadCharUUID,
               characteristic.uuid.uuidString.lowercased() == want {
                ioctlReadValue = data
                handledAsIoctlRead = true
            }
        }

        if handledAsIoctlRead {
            return
        }

        // u-blox SPS: each data notification consumes one credit. Refill before running out.
        if creditsCharacteristic != nil {
            peerCreditBudget -= 1
            if peerCreditBudget <= CoreBluetoothManager.creditLowWater {
                grantCredits(CoreBluetoothManager.creditBatch)
            }
        }

        queue.sync {
            // Preserve packet boundaries (one BLE notification = one entry) for
            // packet-framed protocols. Also keep flat buffer for SLIP-style consumers.
            receivedPackets.append(data)
            receivedData.append(data)
        }

        logDebug("BLE RX: \(data.count) bytes (budget=\(peerCreditBudget))")

        // Signal that data is available - wake up any waiting read
        dataAvailableSemaphore.signal()

        updateTransferStats(data.count)
    }

    /// Synchronously reads a single characteristic value by UUID. Used by `ble_ioctl`
    /// to service DC_IOCTL_BLE_CHARACTERISTIC_READ (Cressi serial/model/firmware reads).
    /// Mirrors the RunLoop-polling pattern used by `discoverServices`.
    /// - Returns: the characteristic value, or nil on timeout / not-found / not-connected.
    @objc(readCharacteristicByUUID:timeout:)
    public func readCharacteristic(byUUID uuidString: String, timeout seconds: Double) -> Data? {
        guard let peripheral = self.peripheral, peripheral.state == .connected else {
            logError("No connected peripheral for characteristic read")
            return nil
        }

        let key = uuidString.lowercased()
        guard let characteristic = queue.sync(execute: { characteristicsByUUID[key] }) else {
            logError("Characteristic \(uuidString) not found in preferred service")
            return nil
        }

        queue.sync {
            ioctlReadValue = nil
            ioctlReadCharUUID = key
        }
        peripheral.readValue(for: characteristic)

        let deadline = Date(timeIntervalSinceNow: seconds)
        while true {
            var result: Data?
            queue.sync { result = ioctlReadValue }
            if let result = result {
                queue.sync { ioctlReadValue = nil; ioctlReadCharUUID = nil }
                return result
            }
            if Date() > deadline {
                queue.sync { ioctlReadCharUUID = nil }
                logError("Timeout reading characteristic \(uuidString)")
                return nil
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        lastWriteError = error
        if let error = error {
            logError("Error writing to characteristic: \(error.localizedDescription)")
        }
        writeConfirmSemaphore.signal()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeReadySemaphore.signal()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error changing notification state: \(error.localizedDescription)")
            return
        }
        // Once the credits characteristic is notifying we must grant the peer
        // an initial credit pool; without this, the OSTC 4/5 won't send the
        // protocol echo and downloads will time out.
        if characteristic === creditsCharacteristic && characteristic.isNotifying {
            sendInitialCredits()
        }
    }

    // MARK: - Private Helpers
    private func updateTransferStats(_ newBytes: Int) {
        totalBytesReceived += newBytes
        
        if let last = lastDataReceived {
            let interval = Date().timeIntervalSince(last)
            if interval > 0 {
                let currentRate = Double(newBytes) / interval
                averageTransferRate = (averageTransferRate * 0.7) + (currentRate * 0.3)
            }
        }
        
        lastDataReceived = Date()
    }
    
    private func isKnownSerialService(_ uuid: CBUUID) -> SerialService? {
        return knownSerialServices.first { service in
            uuid.uuidString.lowercased() == service.uuid.lowercased()
        }
    }
    
    private func isExcludedService(_ uuid: CBUUID) -> Bool {
        return excludedServices.contains(uuid.uuidString.lowercased())
    }
    
    private func isWriteCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.write) ||
               characteristic.properties.contains(.writeWithoutResponse)
    }
    
    private func isReadCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.notify) ||
               characteristic.properties.contains(.indicate)
    }

    @objc public func close() {
        close(clearDevicePtr: false)
    }
}

// MARK: - Extensions
extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
