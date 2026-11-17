import io
import os
import json
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from core.camera_sta_bridge import CameraInternalBridge, ON_CAMERA_AGENT_SCRIPT


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
