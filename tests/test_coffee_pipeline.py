"""Unit and HTTP integration tests for Pocket Coffee Studio pipeline enhancements."""

import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from http.server import HTTPServer
from unittest.mock import patch
from urllib.parse import quote

from core.bean_equipment_store import BeanAndEquipmentManager
from core.camera_sta_bridge import CameraInternalBridge
from core.multimodal_vision import MultimodalVisionEngine
from core.notifier import NotificationManager
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager
from server import app


class TestMultimodalVisionKeyframes(unittest.TestCase):
    def test_extract_video_metadata_and_frames_graceful_fallbacks(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            engine = MultimodalVisionEngine(tmpdir)

            # 1. Synthetic on-camera path fallback
            syn_path = "/mnt/media_rw/emulated/DCIM/DJI_001/DJI_20000103215101_0036_D.MP4"
            syn_meta = engine.extract_video_metadata_and_frames(syn_path)
            self.assertEqual(syn_meta["source_type"], "synthetic_or_missing")
            self.assertFalse(syn_meta["reachable_local"])
            self.assertFalse(syn_meta["extracted_real_frames"])
            self.assertEqual([kf["percentage"] for kf in syn_meta["keyframes"]], [15, 35, 70, 90])

            # 2. Remote camera :8088 HTTP URL fallback + analyze_video_keyframes
            remote_url = "http://192.168.5.93:8088/DJI_001/DJI_20000103215101_0036_D.MP4"
            analysis = engine.analyze_video_keyframes(remote_url, camera_device="DJI Osmo Pocket 4 Pro")
            self.assertEqual(analysis["source_type"], "remote_http")
            self.assertEqual(analysis["video_path"], remote_url)
            self.assertTrue(analysis["video_metadata"]["is_remote_url"])
            self.assertEqual(len(analysis["frame_observations"]), 4)

    def test_extract_video_metadata_and_frames_with_ffmpeg(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            engine = MultimodalVisionEngine(tmpdir)
            local_mp4 = os.path.join(tmpdir, "DJI_0036.MP4")
            with open(local_mp4, "wb") as f:
                f.write(b"\x00\x00\x00\x1cftypisom" + b"\x00" * 128)

            def fake_which(cmd: str):
                if cmd in ("ffprobe", "ffmpeg"):
                    return f"/usr/local/bin/{cmd}"
                return None

            def fake_run(argv, **kwargs):
                exe = os.path.basename(argv[0])
                if exe == "ffprobe":
                    payload = {
                        "streams": [{"width": 3840, "height": 2160, "duration": "80.0"}],
                        "format": {"duration": "80.0", "size": "3449916"},
                    }
                    return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(payload), stderr="")
                if exe == "ffmpeg":
                    out_jpg = argv[-1]
                    os.makedirs(os.path.dirname(out_jpg), exist_ok=True)
                    with open(out_jpg, "wb") as img_f:
                        img_f.write(b"\xff\xd8\xff\xe0MOCKJPEG\xff\xd9")
                    return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
                return subprocess.CompletedProcess(argv, 1, stdout="", stderr="unknown")

            with patch("core.multimodal_vision.shutil.which", side_effect=fake_which), patch(
                "core.multimodal_vision.subprocess.run", side_effect=fake_run
            ):
                meta = engine.extract_video_metadata_and_frames(local_mp4)

            self.assertEqual(meta["source_type"], "local_file")
            self.assertTrue(meta["ffmpeg_available"])
            self.assertTrue(meta["extracted_real_frames"])
            self.assertEqual(meta["extracted_frame_count"], 4)
            self.assertEqual(meta["duration_s"], 80.0)
            self.assertEqual(meta["resolution"], "3840x2160")
            self.assertEqual(meta["size_bytes"], 3449916)
            self.assertIsNone(meta["fallback_reason"])
            self.assertEqual(
                [kf["timestamp_s"] for kf in meta["keyframes"]],
                [12.0, 28.0, 56.0, 72.0],
            )
            for kf in meta["keyframes"]:
                self.assertTrue(kf["extracted"])
                self.assertTrue(os.path.isfile(kf["image_path"]))


class TestCoffeeServerAndComparisonPipeline(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.data_dir = self.temp_dir.name

        self.store = CoffeeStore(self.data_dir)
        self.camera_bridge = CameraInternalBridge(self.data_dir)
        self.notifier = NotificationManager(self.data_dir)
        self.notifier.save_config(
            {
                "mobile_base_url": "http://192.168.5.84:8788",
                "enable_macos_banner": False,
            }
        )
        self.bean_manager = BeanAndEquipmentManager(self.data_dir)
        self.vision_engine = MultimodalVisionEngine(self.data_dir)
        self.voice_manager = VoiceWakeupSessionManager(self.store, self.camera_bridge, self.notifier)

        self.patches = [
            patch.object(app, "store", self.store),
            patch.object(app, "camera_bridge", self.camera_bridge),
            patch.object(app, "notifier", self.notifier),
            patch.object(app, "bean_manager", self.bean_manager),
            patch.object(app, "vision_engine", self.vision_engine),
            patch.object(app, "voice_manager", self.voice_manager),
            patch("usb.core.find", return_value=None),
        ]
        for p in self.patches:
            p.start()

        self.server = HTTPServer(("127.0.0.1", 0), app.CoffeeRequestHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        for p in reversed(self.patches):
            p.stop()
        self.temp_dir.cleanup()

    def request_json(self, method: str, path: str, body=None):
        conn = HTTPConnection(*self.server.server_address)
        payload = json.dumps(body) if body is not None else None
        conn.request(method, path, body=payload, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8")
        conn.close()
        return resp.status, json.loads(raw)

    def test_notifier_default_port_8788_and_verified_dcim_default(self) -> None:
        with tempfile.TemporaryDirectory() as fresh_dir:
            nm = NotificationManager(fresh_dir)
            self.assertEqual(nm.load_config()["mobile_base_url"], "http://192.168.5.84:8788")

        res = self.voice_manager.stop_and_process(
            override_transcript=(
                "我要开始制作咖啡。今天用的是埃塞俄比亚花魁 18克，"
                "独立磨豆机 Niche Zero 刻度 15，做意式浓缩，压力 9 bar，萃取 28 秒，出液 36 克。"
            )
        )
        self.assertTrue(res["video_path"].startswith("/mnt/media_rw/emulated/DCIM/DJI_001/DJI_"))
        self.assertNotIn("/storage/sdcard0/", res["video_path"])
        self.assertIn(":8788/", res["notification"]["report_url"])

    def test_camera_webhook_with_media_url_and_media_endpoint(self) -> None:
        media_url = "http://192.168.5.93:8088/DJI_001/DJI_20000103215101_0036_D.MP4"
        cam_file = "/mnt/media_rw/emulated/DCIM/DJI_001/DJI_20000103215101_0036_D.MP4"

        state = self.camera_bridge.load_state()
        state["cameras"]["pocket4p"]["lan_ip"] = "192.168.5.93"
        state["cameras"]["pocket4p"]["verification"] = {
            "verified_sta_ip": "192.168.5.93",
            "media_http_verified": True,
            "media_http_url": media_url,
        }
        self.camera_bridge.save_state(state)

        status, webhook_res = self.request_json(
            "POST",
            "/api/camera/webhook",
            {
                "device_id": "pocket4p",
                "file_path": cam_file,
                "media_url": media_url,
                "transcript": (
                    "我要开始制作咖啡。今天豆子用的是巴拿马瑰夏浅烘，称重 18 克，"
                    "额外独立磨豆机 DF64 刻度 13 格，做意式浓缩，9 bar 萃取 29 秒，出液 36 克。"
                ),
            },
        )
        self.assertEqual(status, 200)
        self.assertTrue(webhook_res["ok"])
        self.assertTrue(webhook_res["webhook_processed"])
        self.assertEqual(webhook_res["media_url"], media_url)
        self.assertEqual(webhook_res["record"]["video_path"], media_url)
        self.assertEqual(webhook_res["vision_analysis"]["source_type"], "remote_http")

        mock_remote_files = {
            "ok": True,
            "files": [{"name": "DJI_20000103215101_0036_D.MP4", "size_bytes": 3449916, "url": media_url}],
        }
        with patch.object(self.camera_bridge, "list_remote_media", create=True, return_value=mock_remote_files):
            m_status, m_data = self.request_json("GET", "/api/camera/media?device_id=pocket4p")
        self.assertEqual(m_status, 200)
        self.assertTrue(m_data["ok"])
        self.assertEqual(m_data["latest_media_url"], media_url)
        self.assertEqual(m_data["dcim_root"], "/mnt/media_rw/emulated/DCIM/DJI_001")
        self.assertEqual(len(m_data["files"]), 1)

    def test_records_compare_endpoint_side_by_side_deltas(self) -> None:
        # Baseline fast shot (older)
        self.voice_manager.stop_and_process(
            override_transcript=(
                "开始做咖啡。今天咖啡豆用的是埃塞俄比亚花魁7.0日晒中浅烘，豆子称重 18 克，"
                "额外独立磨豆机 Niche Zero，研磨度调到刻度 15.5 格，做意式浓缩，"
                "萃取压力 8.8 bar，萃取时间 20 秒，出液量 40 克。"
            )
        )
        # Dialed-in finer shot (latest)
        self.voice_manager.stop_and_process(
            override_transcript=(
                "开始做咖啡。今天咖啡豆用的是埃塞俄比亚花魁7.0日晒中浅烘，豆子称重 18.5 克，"
                "额外独立磨豆机 Niche Zero，研磨度调到刻度 14.5 格，做意式浓缩，"
                "萃取压力 9.1 bar，萃取时间 29 秒，出液量 37 克。"
            )
        )

        status, cmp_res = self.request_json("GET", f"/api/records/compare?bean={quote('花魁')}")
        self.assertEqual(status, 200)
        self.assertTrue(cmp_res["ok"])
        self.assertGreaterEqual(cmp_res["matched_count"], 2)

        pd = cmp_res["parameter_deltas"]
        self.assertAlmostEqual(pd["bean_weight_g"]["delta"], 0.5)
        self.assertAlmostEqual(pd["grind_setting"]["delta"], -1.0)
        self.assertEqual(pd["grind_setting"]["direction"], "finer")
        self.assertAlmostEqual(pd["yield_g"]["delta"], -3.0)
        self.assertAlmostEqual(pd["extraction_time_s"]["delta"], 9.0)
        self.assertAlmostEqual(pd["pressure_bar"]["delta"], 0.3)

        fd = cmp_res["flavor_radar_delta"]
        self.assertIn("sweetness", fd)
        self.assertGreater(fd["sweetness"]["delta"], 0.0)
        self.assertTrue(len(cmp_res["insights"]) >= 1)


if __name__ == "__main__":
    unittest.main()
