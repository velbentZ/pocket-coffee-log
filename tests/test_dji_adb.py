import json
import os
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from core.camera_sta_bridge import CameraInternalBridge, build_duml_packet
from daemon.investigate_usb import classify
from daemon.patch_dji_adb import patch_bytes


class TestDjiAdb(unittest.TestCase):
    def test_frames_are_not_confused(self):
        self.assertEqual(classify(build_duml_packet(2, 0, 1, 0, 0, 0)), 'duml_crc_valid')
        header = struct.pack('<6I', 0x4e584e43, 0x1000000, 4096, 0, 0, 0xb1a7b1bc)
        self.assertEqual(classify(header), 'adb_header_CNXN')
        self.assertEqual(classify(header[:-1] + b'\0'), 'unknown')
        self.assertEqual(classify(b'CNXN'), 'unknown')

    def test_unknown_binary_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unrecognized'):
            patch_bytes(b'not the inspected binary')

    def test_offline_and_other_devices_never_run_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge = CameraInternalBridge(directory)
            state = bridge.load_state()
            state['cameras']['pocket4p']['adb_serial'] = 'camera'
            bridge.save_state(state)
            with patch('core.camera_sta_bridge.subprocess.run', return_value=
                       subprocess.CompletedProcess([], 0, 'camera offline\nphone device\n', '')) as run:
                result = bridge.execute_internal_command('pocket4p', 'id')
            self.assertFalse(result['ok'])
            self.assertEqual(run.call_count, 1)

    def test_explicit_usb_transport_and_shell_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge = CameraInternalBridge(directory)
            state = bridge.load_state()
            state['cameras']['pocket4p']['adb_serial'] = 'camera'
            bridge.save_state(state)
            with patch.dict(os.environ, {'POCKET_ADB': '/tmp/adb_dji', 'POCKET_ADB_PORT': '5038'}), patch(
                    'core.camera_sta_bridge.subprocess.run', side_effect=[
                        subprocess.CompletedProcess([], 0, 'camera device usb:123\n', ''),
                        subprocess.CompletedProcess([], 1, '', 'permission denied')]) as run:
                result = bridge.execute_internal_command('pocket4p', 'id')
            self.assertFalse(result['ok'])
            self.assertEqual(result['stderr'], 'permission denied')
            self.assertEqual(run.call_args.args[0], ['/tmp/adb_dji', '-P', '5038', '-s', 'camera', 'shell', 'id'])

    def test_tcp_requires_adb_device_not_just_open_socket(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge = CameraInternalBridge(directory)
            with patch('core.camera_sta_bridge.subprocess.run', return_value=
                       subprocess.CompletedProcess([], 0, '192.168.5.108:5555 unauthorized\n', '')):
                self.assertFalse(bridge.adb_transport('pocket4p')['ok'])
