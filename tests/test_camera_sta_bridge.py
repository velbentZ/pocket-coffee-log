import io
import os
import json
import struct
import subprocess
from pathlib import Path
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from core.camera_sta_bridge import CameraInternalBridge, ON_CAMERA_AGENT_SCRIPT
from core import camera_sta_bridge


class CameraSTABridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bridge = CameraInternalBridge(self.temp.name)
        state = self.bridge.load_state()
        state['cameras']['pocket4p']['lan_ip'] = '192.168.5.93'
        self.bridge.save_state(state)

    def test_heartbeat_retains_optional_telemetry(self):
        payload = dict(device_id='pocket4p', ip='192.168.5.93',
                       mac_address='88:22:33:77:33:99', wifi_mode='STA',
                       sd_free_gb=42.25, latest_media_file='DJI_0036.MP4',
                       latest_media_url='http://192.168.5.93:8088/DJI_001/DJI_0036.MP4')
        self.assertTrue(self.bridge.record_heartbeat(payload, payload['ip'])['ok'])
        camera = self.bridge.load_state()['cameras']['pocket4p']
        for key in ('sd_free_gb', 'latest_media_file', 'latest_media_url'):
            self.assertEqual(camera.get(key), payload[key])
        for key in ('sd_free_gb', 'latest_media_file', 'latest_media_url'):
            del payload[key]
        self.bridge.record_heartbeat(payload, payload['ip'])
        self.assertEqual(self.bridge.load_state()['cameras']['pocket4p']['sd_free_gb'], 42.25)

    def test_heartbeat_accepts_battery_and_recording_observations(self):
        payload = dict(device_id='pocket4p', ip='192.168.5.93',
                       mac_address='88:22:33:77:33:99', wifi_mode='STA',
                       battery_percent=72, recording_state='recording')
        self.bridge.record_heartbeat(payload, payload['ip'])
        camera = self.bridge.sta_status()['cameras']['pocket4p']
        self.assertEqual(camera['battery_percent'], 72)
        self.assertEqual(camera['recording_state'], 'recording')
        self.bridge.record_heartbeat(dict(payload, battery_percent=50, recording_state='idle'),
                                     '192.168.5.92')
        for invalid in (True, -1, 101, '72'):
            self.bridge.record_heartbeat(dict(payload, battery_percent=invalid,
                                              recording_state='guessed'), payload['ip'])
        camera = self.bridge.sta_status()['cameras']['pocket4p']
        self.assertEqual(camera['battery_percent'], 72)
        self.assertEqual(camera['recording_state'], 'recording')
        self.bridge.record_heartbeat(dict(payload, battery_percent=None), payload['ip'])
        self.assertIsNone(self.bridge.sta_status()['cameras']['pocket4p']['battery_percent'])

    def test_gimbal_angle_packet_uses_signed_tenths_and_valid_crcs(self):
        packet = camera_sta_bridge.build_gimbal_angle_packet(-25, 1.5, -15, 1.2, seq=0x1234)
        self.assertEqual(len(packet), 21)
        self.assertEqual(packet[:3], b'\x55\x15\x04')
        self.assertEqual(packet[3], camera_sta_bridge.crc8_dji(packet[:3]))
        self.assertEqual(packet[4:11], b'\x02\x04\x34\x12\x40\x04\x14')
        self.assertEqual(struct.unpack('<hhhBB', packet[11:-2]), (-250, 15, -150, 7, 12))
        self.assertEqual(int.from_bytes(packet[-2:], 'little'), camera_sta_bridge.crc16_dji(packet[:-2]))

    def test_move_gimbal_preset_dispatches_same_frame_on_usb_and_udp(self):
        usb = ModuleType('usb')
        device = Mock()
        device.get_active_configuration.return_value = {(4, 0): [SimpleNamespace(bEndpointAddress=4)]}
        device.write.side_effect = lambda ep, frame, **kw: len(frame)
        usb.core = SimpleNamespace(find=Mock(return_value=device))
        usb.util = SimpleNamespace(claim_interface=Mock(), release_interface=Mock())
        with patch.dict('sys.modules', {'usb': usb, 'usb.core': usb.core, 'usb.util': usb.util}), \
                patch('core.camera_sta_bridge.socket.socket') as socket_factory:
            sock = socket_factory.return_value.__enter__.return_value
            sock.sendto.side_effect = lambda frame, target: len(frame)
            result = self.bridge.move_gimbal_preset(preset='scale_dose', yaw_deg=0)
        frame = camera_sta_bridge.build_gimbal_angle_packet(-25, yaw_deg=0, duration_s=1.2)
        usb.util.claim_interface.assert_called_once_with(device, 4)
        device.write.assert_called_once_with(4, frame, timeout=200)
        usb.util.release_interface.assert_called_once_with(device, 4)
        sock.sendto.assert_called_once_with(frame, ('192.168.5.93', 9004))
        self.assertTrue(result['ok'])
        self.assertTrue(result['usb_dispatched'])
        self.assertEqual(result['udp_dispatched_to'], '192.168.5.93')
        self.assertFalse(result['movement_confirmed'])
        self.assertEqual(self.bridge.load_state()['command_log'][0], result['log_entry'])

    def test_move_gimbal_records_dispatch_failure_and_rejects_invalid_inputs(self):
        usb = ModuleType('usb')
        usb.core = SimpleNamespace(find=Mock(return_value=None))
        usb.util = SimpleNamespace()
        with patch.dict('sys.modules', {'usb': usb, 'usb.core': usb.core, 'usb.util': usb.util}), \
                patch('core.camera_sta_bridge.socket.socket', side_effect=OSError('network down')) as sock:
            self.assertFalse(self.bridge.move_gimbal_preset(preset='typo')['ok'])
            self.assertFalse(self.bridge.move_gimbal_preset(pitch_deg=float('nan'))['ok'])
            sock.assert_not_called()
            result = self.bridge.move_gimbal_preset()
        self.assertFalse(result['ok'])
        self.assertFalse(result['usb_dispatched'])
        self.assertIsNone(result['udp_dispatched_to'])
        self.assertIn('network down', result['log_entry']['output'])

    def test_auto_provision_checks_and_starts_installed_agent_over_usb_adb(self):
        argv = ['adb', '-P', '5037', '-s', '123456789ABCDEF']
        transport = {'ok': True, 'transport': 'usb', 'argv': argv, 'serial': argv[-1]}
        with patch.object(self.bridge, 'adb_transport', return_value=transport) as adb, \
                patch.object(self.bridge, 'provision_sta_mode') as provision:
            for status in ('started', 'already_running', 'not_installed'):
                with self.subTest(status=status), patch(
                    'core.camera_sta_bridge.subprocess.run',
                    return_value=subprocess.CompletedProcess([], 0, status + '\n', ''),
                ) as run:
                    result = self.bridge.auto_provision_if_usb_connected()
                    self.assertTrue(result['usb_connected'])
                    self.assertEqual(result['agent_status']['status'], status)
                    args = run.call_args.args[0]
                    self.assertEqual(args[:-1], argv + ['shell'])
                    self.assertIn('/data/pocket-coffee/pocket_sta_agent.sh', args[-1])
                    self.assertIn('busybox nohup /system/bin/sh', args[-1])
            provision.assert_not_called()
            self.assertEqual(adb.call_count, 3)
            adb.assert_called_with('pocket4p')

    def test_auto_provision_does_not_start_agent_over_adb_tcp(self):
        with patch.object(self.bridge, 'adb_transport', return_value={'ok': True, 'transport': 'tcp'}), \
                patch.object(self.bridge, 'query_live_usb_camera_info', return_value={'connected': False}), \
                patch('core.camera_sta_bridge.subprocess.run') as shell:
            self.assertFalse(self.bridge.auto_provision_if_usb_connected()['usb_connected'])
            shell.assert_not_called()

    def test_agent_recovery_shell_ignores_reused_pid_and_launches_once(self):
        root = Path(self.temp.name)
        (root / 'proc/42').mkdir(parents=True)
        (root / 'proc/42/cmdline').write_bytes(b'/system/bin/unrelated\0')
        (root / 'agent.pid').write_text('42\n')
        agent = root / 'pocket_sta_agent.sh'
        agent.unlink()  # Bridge construction exports a copy into this directory.
        command = camera_sta_bridge._ADB_ENSURE_STA_AGENT.replace(
            '/data/pocket-coffee', str(root)).replace('/proc/', f'{root}/proc/')
        # Emulate the firmware's BusyBox, shell and procfs using local fixtures.
        command = 'busybox() { "$@"; }\n' + command.replace(
            'busybox nohup /system/bin/sh', 'busybox nohup sh')

        def run_recovery():
            return subprocess.run(['sh', '-c', command], capture_output=True, text=True, check=True)

        self.assertEqual(run_recovery().stdout.strip(), 'not_installed')
        agent.write_text(r'''base="${0%/*}"
printf '%s\0%s\0' /system/bin/sh "$0" > "$base/proc/42/cmdline"
echo launched >> "$base/launches"
''')
        self.assertEqual(run_recovery().stdout.strip(), 'started')
        self.assertEqual(run_recovery().stdout.strip(), 'already_running')
        self.assertEqual((root / 'launches').read_text(), 'launched\n')

    @patch('core.camera_sta_bridge.urllib_request.urlopen', side_effect=OSError('no index'))
    def test_media_list_falls_back_to_real_adb_listing(self, _):
        listing = '-rw-rw---- 1 1023 1023 1234 Jan 3 13:51 DJI_0036.MP4\n-rw-rw---- 1 1023 1023 456 Jan 3 13:50 DJI_0035.MP4'
        with patch.object(self.bridge, 'execute_internal_command', return_value={'ok': True, 'output': listing}):
            result = self.bridge.list_remote_media()
        self.assertTrue(result['ok'])
        self.assertEqual(result['files'][0]['name'], 'DJI_0036.MP4')
        self.assertEqual(result['files'][0]['size_bytes'], 1234)
        self.assertEqual(result['files'][0]['url'], 'http://192.168.5.93:8088/DJI_001/DJI_0036.MP4')

    def test_media_list_http_index(self):
        response = io.BytesIO(b'<a href="DJI_0036.MP4">video</a><a href="../bad.MP4">bad</a>')
        head = io.BytesIO()
        head.headers = {'Content-Length': '1234', 'Last-Modified': 'Mon, 03 Jan 2000 13:51:03 GMT'}
        with patch('core.camera_sta_bridge.urllib_request.urlopen', side_effect=[response, head]):
            result = self.bridge.list_remote_media()
        self.assertTrue(result['ok'])
        self.assertEqual(len(result['files']), 1)
        self.assertEqual(result['files'][0]['size_bytes'], 1234)

    def test_media_list_reports_failure(self):
        with patch('core.camera_sta_bridge.urllib_request.urlopen', side_effect=OSError('down')), patch.object(self.bridge, 'execute_internal_command', return_value={'ok': False, 'error': 'offline'}):
            self.assertFalse(self.bridge.list_remote_media()['ok'])

    def test_pull_full_and_bounded_download(self):
        media = {'name': 'DJI_0036.MP4', 'url': 'http://192.168.5.93:8088/DJI_001/DJI_0036.MP4', 'size_bytes': 10}
        for limit in (None, 4):
            with self.subTest(limit=limit), patch.object(self.bridge, 'list_remote_media', return_value={'ok': True, 'files': [media]}), patch('core.camera_sta_bridge.urllib_request.urlopen', return_value=io.BytesIO(b'0123456789')):
                result = self.bridge.pull_latest_media(max_bytes=limit)
                self.assertTrue(result['ok'])
                self.assertTrue(os.path.isfile(result['local_path']))
                with open(result['local_path'], 'rb') as downloaded:
                    self.assertEqual(downloaded.read(), b'0123' if limit else b'0123456789')
                self.assertEqual(result['partial'], bool(limit))

    def test_pull_rejects_empty_or_truncated_response(self):
        media = {'name': 'DJI_0036.MP4', 'url': 'http://camera/file', 'size_bytes': 10}
        with patch.object(self.bridge, 'list_remote_media', return_value={'ok': True, 'files': [media]}), patch('core.camera_sta_bridge.urllib_request.urlopen', return_value=io.BytesIO(b'123')):
            self.assertFalse(self.bridge.pull_latest_media()['ok'])

    def test_recording_reports_adb_without_claiming_recording_confirmed(self):
        import builtins
        original_import = builtins.__import__

        def without_usb(name, *args, **kwargs):
            if name.startswith('usb'):
                raise ImportError('USB DUML unavailable in test')
            return original_import(name, *args, **kwargs)

        transport = {'ok': True, 'serial': '123456789ABCDEF', 'transport': 'usb',
                     'argv': ['adb', '-s', '123456789ABCDEF']}
        with patch('builtins.__import__', side_effect=without_usb), patch.object(self.bridge, 'adb_transport', return_value=transport), patch('core.camera_sta_bridge.socket.socket'):
            result = self.bridge.trigger_lan_recording('pocket4p', 'start')
        self.assertTrue(result['adb_status']['ok'])
        self.assertEqual(result['adb_status']['transport'], 'usb')
        self.assertEqual(result['recording_state'], 'unknown')
        self.assertFalse(result['usb_dispatched'])
        camera = self.bridge.load_state()['cameras']['pocket4p']
        self.assertEqual(camera['adb_status']['serial'], '123456789ABCDEF')
        self.assertEqual(camera['recording_requested_action'], 'start')

    def run_agent_functions(self, commands):
        functions = ON_CAMERA_AGENT_SCRIPT.split('json_escape() {', 1)[1].split("log 'Starting STA agent", 1)[0]
        shell = 'json_escape() {' + functions + r"""
BB=bb
bb() {
    case "$1" in
        df) printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/block/by-name/media\n 109242368 3108352 106134016 3%% /mnt/media_rw/emulated\n';;
        stat) printf '%s\n' "$FAKE_SIZE";;
        *) "$@";;
    esac
}
log() { :; }
newest_mp4() { printf '%s' "$FAKE_NEW"; }
post_json() { printf '%s\n' "$2"; return 0; }
CURRENT_IP=192.168.5.93
DEVICE_ID=pocket4p
WIFI_SSID=coffee
""" + commands
        result = subprocess.run(['sh'], input=shell + '\n:', text=True, capture_output=True,
                                env={**os.environ, 'BASE_DIR': self.temp.name}, check=True)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_agent_reads_wrapped_df_telemetry(self):
        payloads = self.run_agent_functions('FAKE_NEW=/media/clip.MP4; heartbeat')
        self.assertEqual(payloads[0]['sd_free_gb'], 101.217)
        self.assertEqual(payloads[0]['latest_media_file'], 'clip.MP4')
        self.assertEqual(payloads[0]['latest_media_url'], 'http://192.168.5.93:8088/DJI_001/clip.MP4')

    def test_agent_reports_battery_capacity_only_for_a_battery(self):
        supply = Path(self.temp.name, 'battery')
        supply.mkdir()
        (supply / 'capacity').write_text('072\n')
        (supply / 'type').write_text('Mains\n')
        self.assertIsNone(self.run_agent_functions('POWER_SUPPLY_DIR="$BASE_DIR"; heartbeat')[0]['battery_percent'])
        (supply / 'type').write_text('Battery\n')
        self.assertEqual(self.run_agent_functions('POWER_SUPPLY_DIR="$BASE_DIR"; heartbeat')[0]['battery_percent'], 72)
        (supply / 'capacity').write_text('101\n')
        self.assertIsNone(self.run_agent_functions('POWER_SUPPLY_DIR="$BASE_DIR"; heartbeat')[0]['battery_percent'])

    def test_agent_watcher_waits_for_stable_size_and_deduplicates(self):
        payloads = self.run_agent_functions(r"""
printf '%s\n' old.MP4 > "$BASE_DIR/last_mp4.txt"
FAKE_NEW=/media/old.MP4; FAKE_SIZE=100; watch_mp4
FAKE_NEW=/media/new.MP4; FAKE_SIZE=100; watch_mp4
FAKE_SIZE=200; watch_mp4
FAKE_SIZE=300; watch_mp4
watch_mp4
watch_mp4
""")
        self.assertEqual(len(payloads), 1)
        self.assertEqual(payloads[0]['file_path'], '/media/new.MP4')
        self.assertEqual(payloads[0]['media_url'], 'http://192.168.5.93:8088/DJI_001/new.MP4')
        self.assertEqual(Path(self.temp.name, 'last_mp4.txt').read_text().strip(), 'new.MP4')


if __name__ == '__main__':
    unittest.main()
