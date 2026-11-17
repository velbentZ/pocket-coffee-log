"""Exercise heartbeat ingestion through the real HTTP handler and config file."""
import copy
import json
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from http.server import HTTPServer
from unittest.mock import patch
from core.camera_sta_bridge import CameraInternalBridge
from server import app


class TestCameraHeartbeat(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.bridge = CameraInternalBridge(self.directory.name)
        self.patch = patch.object(app, 'camera_bridge', self.bridge)
        self.patch.start()
        self.server = HTTPServer(('127.0.0.1', 0), app.CoffeeRequestHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.patch.stop()
        self.directory.cleanup()

    def request(self, method, path, body=None):
        connection = HTTPConnection(*self.server.server_address)
        connection.request(method, path, json.dumps(body) if body is not None else None,
                           {'Content-Type': 'application/json'})
        response = connection.getresponse()
        result = response.status, json.loads(response.read())
        connection.close()
        return result

    def payload(self):
        return dict(device_id='pocket4p', ip='192.168.5.122', mac_address='88:22:33:77:33:99',
                    ssid='Home_Coffee_LAN', wifi_mode='STA', agent_version='v3-hg224')

    def test_heartbeat_persists_observation_and_status_without_credentials(self):
        status, result = self.request('POST', '/api/camera/heartbeat', self.payload())
        self.assertEqual(status, 200)
        self.assertTrue(result['ok'])
        camera = self.bridge.load_state()['cameras']['pocket4p']
        self.assertEqual(camera['lan_ip'], '192.168.5.122')
        self.assertEqual(camera['mac_address'], '88:22:33:77:33:99')
        self.assertTrue(camera['last_heartbeat'])
        # A localhost unit-test POST must not claim verified LAN transport.
        self.assertFalse(camera['verification']['sta_connection_verified'])
        status, state = self.request('GET', '/api/camera/sta')
        self.assertEqual(status, 200)
        self.assertNotIn('password', state['sta_network'])
        self.assertEqual(state['cameras']['pocket4p']['last_heartbeat'], camera['last_heartbeat'])

    def test_rejects_unknown_camera_invalid_mac_and_non_sta_addresses(self):
        original = copy.deepcopy(self.bridge.load_state())
        for updates in ({'device_id': 'phone'}, {'ip': '192.168.2.1'},
                        {'ip': 'invalid'}, {'mac_address': 'bad'}, {'wifi_mode': 'AP'}):
            with self.subTest(updates=updates):
                status, result = self.request('POST', '/api/camera/heartbeat', {**self.payload(), **updates})
                self.assertEqual(status, 400)
                self.assertFalse(result['ok'])
                self.assertEqual(self.bridge.load_state(), original)

    def test_same_lan_source_verifies_sta_but_never_boot_persistence(self):
        result = self.bridge.record_heartbeat(self.payload(), '192.168.5.122')
        self.assertTrue(result['ok'])
        camera = self.bridge.load_state()['cameras']['pocket4p']
        self.assertTrue(camera['verification']['sta_connection_verified'])
        self.assertFalse(camera['verification'].get('persistence_verified', False))

class TestUnobservedCamera(unittest.TestCase):
    def test_new_config_never_invents_hardware_observations(self):
        with tempfile.TemporaryDirectory() as directory:
            state = CameraInternalBridge(directory).load_state()
            self.assertEqual(state['command_log'], [])
            for camera in state['cameras'].values():
                self.assertEqual(camera['lan_ip'], '')
                self.assertEqual(camera['last_heartbeat'], '')
                self.assertFalse(camera['internal_daemon_installed'])
                self.assertEqual(camera['capabilities'], [])
