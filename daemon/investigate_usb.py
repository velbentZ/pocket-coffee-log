#!/usr/bin/env python3
"""Probe DJI engineering bulk interfaces without undocumented mode setters.

Default: descriptors, endpoint status, passive reads. --adb sends CNXN in
separate header/payload transfers. --clear-halt clears each candidate endpoint.
No device reset, driver detach, network setter, or USB configuration change.
"""
import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core.camera_sta_bridge import crc8_dji, crc16_dji


def classify(data):
    if len(data) >= 24:
        command, version, maximum, length, checksum, magic = struct.unpack('<6I', data[:24])
        if command in (0x4e584e43, 0x48545541) and magic == command ^ 0xffffffff and length <= 1048576:
            return 'adb_header_' + data[:4].decode('ascii')
    if len(data) >= 13 and data[0] == 0x55:
        length = int.from_bytes(data[1:3], 'little') & 0x3ff
        if (13 <= length <= len(data) and crc8_dji(data[:3]) == data[3]
                and crc16_dji(data[:length-2]) == int.from_bytes(data[length-2:length], 'little')):
            return 'duml_crc_valid'
    # A prefix alone does not establish a serial console or HDC session.
    return 'unknown'


def probe(clear_halt=False, adb=False):
    import usb.core
    import usb.control
    import usb.util
    device = usb.core.find(idVendor=0x2ca3, idProduct=0x20)
    if device is None:
        return {'error': 'DJI 2ca3:0020 not connected', 'interfaces': []}
    result = {'product': device.product, 'serial': device.serial_number, 'interfaces': []}
    try:
        for interface in device.get_active_configuration():
            if interface.bInterfaceNumber not in (3, 4, 5, 6, 7) or interface.bAlternateSetting:
                continue
            row = {'number': interface.bInterfaceNumber, 'class': interface.bInterfaceClass,
                   'subclass': interface.bInterfaceSubClass, 'protocol': interface.bInterfaceProtocol,
                   'endpoints': [], 'attempts': []}
            result['interfaces'].append(row)
            claimed = False
            try:
                usb.util.claim_interface(device, interface.bInterfaceNumber)
                claimed = True
                for ep in interface:
                    status = usb.control.get_status(device, ep)
                    item = {'address': ep.bEndpointAddress, 'status': status,
                            'max_packet_size': ep.wMaxPacketSize}
                    row['endpoints'].append(item)
                    if clear_halt or status & 1:
                        device.clear_halt(ep.bEndpointAddress)
                        item['status_after_clear'] = usb.control.get_status(device, ep)
                bulk = [ep for ep in interface if usb.util.endpoint_type(ep.bmAttributes) == 2]
                out = next(ep.bEndpointAddress for ep in bulk if not ep.bEndpointAddress & 128)
                inp = next(ep.bEndpointAddress for ep in bulk if ep.bEndpointAddress & 128)
                try:
                    data = bytes(device.read(inp, 4096, timeout=250))
                    row['passive'] = {'hex': data.hex(), 'classification': classify(data)}
                except usb.core.USBError as error:
                    row['passive_error'] = str(error)
                if adb:
                    for version, maximum, banner in [(0x1000000, 4096, b'host::\0'),
                            (0x1000001, 1048576, b'host::features=shell_v2,cmd,stat_v2\0')]:
                        attempt = {'version': version, 'maximum': maximum, 'stage': 'header_write'}
                        row['attempts'].append(attempt)
                        try:
                            header = struct.pack('<6I', 0x4e584e43, version, maximum,
                                                 len(banner), sum(banner), 0xb1a7b1bc)
                            attempt['header_written'] = device.write(out, header, timeout=1000)
                            attempt['stage'] = 'payload_write'
                            attempt['payload_written'] = device.write(out, banner, timeout=1000)
                            attempt['stage'] = 'read'
                            data = bytes(device.read(inp, 4096, timeout=1500))
                            attempt.update(hex=data.hex(), classification=classify(data), stage='received')
                        except usb.core.USBError as error:
                            attempt['error'] = str(error)
            except Exception as error:
                row['error'] = str(error)
            finally:
                if claimed:
                    usb.util.release_interface(device, interface.bInterfaceNumber)
    finally:
        usb.util.dispose_resources(device)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', action='store_true')
    parser.add_argument('--clear-halt', action='store_true')
    args = parser.parse_args()
    print(json.dumps(probe(args.clear_halt, args.adb), indent=2))
