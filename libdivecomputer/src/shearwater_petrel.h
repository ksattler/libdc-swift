/*
 * libdivecomputer
 *
 * Copyright (C) 2013 Jef Driesen
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301 USA
 */

#ifndef SHEARWATER_PETREL_H
#define SHEARWATER_PETREL_H

#include <libdivecomputer/context.h>
#include <libdivecomputer/iostream.h>
#include <libdivecomputer/device.h>
#include <libdivecomputer/parser.h>

#ifdef __cplusplus
extern "C" {
#endif /* __cplusplus */

dc_status_t
shearwater_petrel_device_open (dc_device_t **device, dc_context_t *context, dc_iostream_t *iostream);

/*
 * Dive selection (libdc-swift extension).
 *
 * shearwater_petrel_device_list reads only the manifest and reports the
 * fingerprint (start time in device ticks) of every dive on the device,
 * newest first, ignoring the fingerprint set with dc_device_set_fingerprint.
 * Returning 0 from the callback stops the enumeration.
 *
 * shearwater_petrel_device_set_selection restricts subsequent foreach calls
 * to the dives with the given fingerprints (count * 4 bytes). While a
 * selection is set the device fingerprint is ignored. Pass count 0 to clear.
 */
typedef int (*shearwater_petrel_manifest_callback_t) (const unsigned char *fingerprint, unsigned int fsize, void *userdata);

dc_status_t
shearwater_petrel_device_list (dc_device_t *device, shearwater_petrel_manifest_callback_t callback, void *userdata);

dc_status_t
shearwater_petrel_device_set_selection (dc_device_t *device, const unsigned char data[], unsigned int count);

dc_status_t
shearwater_petrel_parser_create (dc_parser_t **parser, dc_context_t *context, const unsigned char data[], size_t size, unsigned int model);

#ifdef __cplusplus
}
#endif /* __cplusplus */
#endif /* SHEARWATER_PETREL_H */
