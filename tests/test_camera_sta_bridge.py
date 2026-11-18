import io
import os
import json
import struct
import subprocess
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from core.camera_sta_bridge import CameraInternalBridge, ON_CAMERA_AGENT_SCRIPT
from core import camera_sta_bridge
from daemon import provision_camera_sta


class CameraSTABridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bridge = CameraInternalBridge(self.temp.name)
        state = self.bridge.load_state()
        state['cameras']['pocket4p']['lan_ip'] = '192.168.5.93'
        self.bridge.save_state(state)

    def test_auto_recovery_skips_fresh_heartbeat(self):
        with patch.object(self.bridge, 'ensure_sta_agent_over_usb') as usb:
            self.bridge.record_heartbeat(dict(device_id='pocket4p', ip='192.168.5.93',
                mac_address='88:22:33:77:33:99', wifi_mode='STA'), '192.168.5.93')
            self.assertEqual(self.bridge.recover_camera_once()['status'], 'healthy')
            usb.assert_not_called()

    def test_auto_recovery_restarts_stale_agent_over_usb(self):
        self.bridge.record_heartbeat(dict(device_id='pocket4p', ip='192.168.5.93',
            mac_address='88:22:33:77:33:99', wifi_mode='STA'), '192.168.5.93')
        state = self.bridge.load_state()
        state['cameras']['pocket4p']['last_heartbeat'] = (
            datetime.now(timezone.utc) - timedelta(seconds=21)).isoformat()
        self.bridge.save_state(state)
        with patch.object(self.bridge, 'ensure_sta_agent_over_usb',
                          return_value={'ok': True, 'status': 'started'}), \
             patch.object(self.bridge, 'ensure_sta_agent_over_lan') as lan:
            result = self.bridge.recover_camera_once()
        self.assertEqual((result['transport'], result['status']), ('usb', 'started'))
        self.assertFalse(result['heartbeat_fresh'])
        self.assertEqual(self.bridge.sta_status()['auto_recovery']['status'], 'started')
        lan.assert_not_called()

    def test_auto_recovery_uses_ble_then_tries_agent_over_lan(self):
        with patch.object(self.bridge, 'ensure_sta_agent_over_usb',
                          return_value={'ok': False, 'status': 'usb_unavailable'}), \
             patch.object(self.bridge, 'ensure_sta_agent_over_lan',
                          side_effect=[{'ok': False, 'status': 'lan_adb_unavailable'},
                                       {'ok': True, 'status': 'started'}]) as lan, \
             patch('daemon.camera_auto_recovery.provision_over_ble',
                   return_value='sta_join_acknowledged'):
            result = self.bridge.recover_camera_once()
        self.assertEqual(lan.call_count, 2)
        self.assertEqual((result['transport'], result['status']), ('ble', 'started'))
        self.assertEqual(result['ble_status'], 'sta_join_acknowledged')
        self.assertFalse(result['heartbeat_fresh'])

    def test_auto_recovery_waits_for_dhcp_before_retrying_ble(self):
        with patch.object(self.bridge, 'ensure_sta_agent_over_usb',
                          return_value={'ok': False, 'status': 'usb_unavailable'}), \
             patch.object(self.bridge, 'ensure_sta_agent_over_lan',
                          return_value={'ok': False, 'status': 'lan_adb_unavailable'}), \
             patch('daemon.camera_auto_recovery.provision_over_ble',
                   return_value='sta_join_acknowledged') as ble:
            self.assertEqual(self.bridge.recover_camera_once()['status'], 'waiting_for_lan')
            self.assertEqual(self.bridge.recover_camera_once()['status'], 'waiting_for_lan')
        ble.assert_called_once()
        recovery = self.bridge.sta_status()['auto_recovery']
        self.assertEqual(recovery['last_ble_attempt']['status'], 'sta_join_acknowledged')
        self.assertFalse(recovery['heartbeat_fresh'])

    def test_ble_station_packet_payloads(self):
        from daemon import camera_auto_recovery as recovery
        pairing = recovery.build_ble_pairing_packet('client', 'osmo', 0x1234)
        mode = recovery.build_ble_sta_mode_packet(0x1235)
        join = recovery.build_ble_sta_join_packet('咖啡', 'password', 0x1236)
        for frame, seq, command in ((pairing, 0x34, 0x45), (mode, 0x35, 0x48),
                                    (join, 0x36, 0x47)):
            self.assertEqual(frame[4:11], bytes((2, 7, seq, 0x12, 0x40, 7, command)))
            self.assertEqual(int.from_bytes(frame[1:3], 'little') & 0x3ff, len(frame))
            self.assertEqual(int.from_bytes(frame[-2:], 'little'), camera_sta_bridge.crc16_dji(frame[:-2]))
        self.assertEqual(pairing[11:-2], b'\x06client\x04osmo')
        self.assertEqual(mode[11:-2], b'\x01')
        self.assertEqual(join[11:-2], b'\x06' + '咖啡'.encode() + b'\x08password')
        with self.assertRaises(ValueError):
            recovery.build_ble_sta_join_packet('咖' * 11, 'password', 1)

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

    def test_pull_selects_newest_named_or_smallest_nonempty_mp4(self):
        files = [dict(name=name, url='http://camera/' + name, size_bytes=size)
                 for name, size in [('new.MP4', 8), ('empty.MP4', 0),
                                    ('small.MP4', 2), ('other.MP4', 4)]]
        for options, selected in [({}, files[0]), ({'prefer_smallest': True}, files[2]),
                                  ({'filename': 'other.MP4'}, files[3])]:
            contents = b'x' * selected['size_bytes']
            with self.subTest(options=options), patch.object(
                self.bridge, 'list_remote_media', return_value={'ok': True, 'files': files},
            ), patch('core.camera_sta_bridge.urllib_request.urlopen', return_value=io.BytesIO(contents)) as get:
                result = self.bridge.pull_latest_media(**options)
                self.assertTrue(result['ok'])
                self.assertFalse(result['partial'])
                self.assertEqual(get.call_args.args[0].full_url, selected['url'])
                self.assertEqual(Path(result['local_path']).name, selected['name'])
                self.assertEqual(Path(result['local_path']).read_bytes(), contents)

    def test_pull_rejects_unlisted_filename_and_conflicting_selection(self):
        media = {'name': 'DJI_0036.MP4', 'url': 'http://camera/file', 'size_bytes': 10}
        with patch.object(self.bridge, 'list_remote_media', return_value={'ok': True, 'files': [media]}), \
                patch('core.camera_sta_bridge.urllib_request.urlopen') as get:
            self.assertFalse(self.bridge.pull_latest_media(filename='../DJI_0036.MP4')['ok'])
            self.assertFalse(self.bridge.pull_latest_media(filename=media['name'], prefer_smallest=True)['ok'])
            get.assert_not_called()

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


class ProvisionCameraCLITests(unittest.TestCase):
    def setUp(self):
        self.bridge = Mock(spec=CameraInternalBridge)
        self.state = {
            'sta_network': {'ssid': '你的名字', 'password': 'test-secret', 'mac_server_ip': '192.168.5.84'},
            'cameras': {'pocket4p': {'lan_ip': '192.168.5.2', 'verification': {'verified_sta_ip': '192.168.5.93'}}},
        }
        self.bridge.load_state.return_value = self.state
        self.bridge.ensure_sta_agent_over_usb.return_value = {
            'ok': True, 'serial': '123456789ABCDEF', 'status': 'already_running',
        }
        self.url = 'http://192.168.5.93:8088/DJI_001/small.MP4'

    def heartbeat(self, observed_at, source='192.168.5.93'):
        camera = self.state['cameras']['pocket4p']
        camera.update(lan_ip='192.168.5.93', wifi_mode='STA', last_heartbeat=observed_at.isoformat(),
                      latest_media_url=self.url)
        camera['verification'].update(heartbeat_verified=True, heartbeat_source_ip=source)

    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(provision_camera_sta, 'CameraInternalBridge', return_value=self.bridge), \
                redirect_stdout(out), redirect_stderr(err):
            status = provision_camera_sta.main(list(args))
        return status, out.getvalue(), err.getvalue()

    def test_status_recovers_agent_and_reports_fresh_heartbeat_at_verified_ip(self):
        def recover(*args, **kwargs):
            self.heartbeat(datetime.now(timezone.utc))
            return self.bridge.ensure_sta_agent_over_usb.return_value

        self.bridge.ensure_sta_agent_over_usb.side_effect = recover
        status, out, _ = self.run_cli('--device', 'pocket4p', '--status')
        self.assertEqual(status, 0)
        self.bridge.ensure_sta_agent_over_usb.assert_called_once_with('pocket4p', restart_if_stopped=True)
        self.bridge.provision_sta_mode.assert_not_called()
        self.bridge.pull_latest_media.assert_not_called()
        self.assertIn('123456789ABCDEF', out)
        self.assertIn('heartbeat', out)
        self.assertIn(self.url, out)
        self.assertNotIn('test-secret', out)

    def test_pull_latest_uses_full_download_and_allows_check_only(self):
        self.bridge.pull_latest_media.return_value = {'ok': True, 'local_path': '/cache/small.MP4', 'size_bytes': 42}
        live = {'last_heartbeat': datetime.now(timezone.utc).isoformat(), 'latest_media_url': self.url}
        with patch.object(provision_camera_sta, '_wait_for_heartbeat', return_value=live):
            status, out, _ = self.run_cli('--pull-latest', '--no-recover-adb')
        self.assertEqual(status, 0)
        self.bridge.ensure_sta_agent_over_usb.assert_called_once_with('pocket4p', restart_if_stopped=False)
        self.bridge.pull_latest_media.assert_called_once_with('pocket4p')
        self.assertIn('/cache/small.MP4', out)

    def test_wait_rejects_cached_or_wrong_source_heartbeat(self):
        now = datetime.now(timezone.utc)
        for observed_at, source in [(now - timedelta(seconds=60), '192.168.5.93'), (now, '192.168.5.2')]:
            with self.subTest(observed_at=observed_at, source=source):
                self.heartbeat(observed_at, source)
                result = provision_camera_sta._wait_for_heartbeat(self.bridge, 'pocket4p', '192.168.5.93', now, timeout=0)
                self.assertIsNone(result)

    def test_legacy_request_uses_config_defaults_and_explicit_overrides(self):
        self.bridge.provision_sta_mode.return_value = {'ok': False, 'error': 'Delivery unverified'}
        for args, expected in [([], ('你的名字', 'test-secret', '192.168.5.93')),
                               (['--ssid', 'Other', '--password', 'override', '--lan-ip', '192.168.5.9'],
                                ('Other', 'override', '192.168.5.9'))]:
            with self.subTest(args=args):
                ssid, password, ip = expected
                status, out, err = self.run_cli('--legacy-duml', *args)
                self.assertEqual(status, 1)
                self.bridge.provision_sta_mode.assert_called_with(
                    device_id='pocket4p', ssid=ssid, password=password, lan_ip=ip, mac_server_ip='192.168.5.84')
                self.assertNotIn(password, out + err)


if __name__ == '__main__':
    unittest.main()
