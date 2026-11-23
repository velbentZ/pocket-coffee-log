import http.client
import json
import os
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest import mock

import server.app as app_module
from core.bean_equipment_store import BeanAndEquipmentManager
from core.camera_sta_bridge import CameraInternalBridge
from core.context_engine import SessionContextCompactor
from core.multimodal_vision import MultimodalVisionEngine, detect_media_kind
from core.notifier import NotificationManager
from core.pipeline import CoffeeIngestionPipeline
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager


def _build_multipart_body(fields, file_field=None):
    boundary = "----PocketCoffeeTestBoundary7MA4YWxkTrZu0gW"
    parts = []
    for k, v in fields.items():
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{k}"\r\n\r\n'
            f"{v}\r\n"
        )
    body = "".join(parts).encode("utf-8")
    if file_field:
        field_name, filename, content_type, data = file_field
        header = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode("utf-8")
        body += header + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode("utf-8")
    return boundary, body


class TestDecoupledModularPipeline(unittest.TestCase):
    def test_detect_media_kind(self):
        self.assertEqual(detect_media_kind("/tmp/note.m4a"), "audio")
        self.assertEqual(detect_media_kind("/tmp/clip.WAV"), "audio")
        self.assertEqual(detect_media_kind("/tmp/iphone.MOV"), "video")
        self.assertEqual(detect_media_kind("http://192.168.5.93:8088/DJI_001/DJI_0001.MP4"), "video")
        self.assertEqual(detect_media_kind(""), "text")

    def test_pipeline_works_without_camera_bridge_for_iphone_and_ipad(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            store = CoffeeStore(tmpdir)
            vision = MultimodalVisionEngine(tmpdir)
            beans = BeanAndEquipmentManager(tmpdir)
            notifier = NotificationManager(tmpdir)
            pipeline = CoffeeIngestionPipeline(store, vision, beans, notifier)

            # 1. Audio-only recognition skips video keyframes
            audio_path = os.path.join(tmpdir, "voice_memo.m4a")
            with open(audio_path, "wb") as f:
                f.write(b"fake-m4a-bytes")

            with mock.patch.object(
                vision,
                "extract_audio_and_transcribe_segments",
                return_value=(
                    "今天用花魁日晒浅烘，称豆18克，独立磨豆机 Niche Zero 刻度14，做意式浓缩，9bar萃取28秒，出液36克。",
                    [{"text": "花魁", "timestamp_s": 1.0, "duration_s": 0.5}],
                ),
            ):
                rec_only = pipeline.recognize_media(
                    media_path=audio_path,
                    source_device="iPhone 16 Pro",
                )
            self.assertEqual(rec_only["media_kind"], "audio")
            self.assertEqual(rec_only["keyframes"], [])
            self.assertIn("花魁", rec_only["transcript"])
            # Recognition alone must NOT persist a record
            initial_count = len(store.list_records())

            # 2. Standalone report generation from recognized output
            gen = pipeline.generate_report(
                transcript=rec_only["transcript"],
                source_device="iPhone 16 Pro",
                source_type="iphone",
                media_kind="audio",
                video_path=audio_path,
                visual_fields=rec_only["visual_fields"],
                frame_observations=rec_only["frame_observations"],
                record_intent="auto",
                save=True,
                notify=False,
            )
            self.assertTrue(gen["saved"])
            self.assertEqual(gen["record_type"], "brew_report")
            self.assertEqual(gen["record"]["camera_device"], "iPhone 16 Pro")
            self.assertEqual(gen["record"]["source_type"], "iphone")
            self.assertEqual(gen["record"]["media_kind"], "audio")
            self.assertEqual(gen["record"]["bean_weight_g"], 18.0)
            self.assertEqual(gen["record"]["yield_g"], 36.0)
            self.assertEqual(len(store.list_records()), initial_count + 1)

            # 3. iPad equipment introduction persists to BeanAndEquipmentManager
            eq_res = pipeline.ingest_media(
                transcript="今天用iPad介绍一下我家里做咖啡的器具，咖啡机是格米莱3828自带豆仓，还有轰炸机自动回弹压粉锤和四桨布粉器，这就是一整套制作的工具。",
                source_device="iPad Pro",
                source_type="ipad",
                record_intent="auto",
                save=True,
                notify=False,
            )
            self.assertEqual(eq_res["record_type"], "equipment_profile")
            self.assertEqual(eq_res["record"]["camera_device"], "iPad Pro")
            self.assertEqual(eq_res["record"]["source_type"], "ipad")
            self.assertIsNotNone(eq_res["equipment_profile_updated"])
            self.assertGreaterEqual(len(eq_res["record"]["equipment_items"]), 2)

            # 4. Non-coffee content is rejected and never saved
            before_non_coffee = len(store.list_records())
            non_coffee = pipeline.ingest_media(
                transcript="今天天气真不错，中午去吃了个火锅，晚上打算看场电影。",
                source_device="iPhone 15 Pro",
                source_type="iphone",
                record_intent="auto",
                save=True,
                notify=False,
            )
            self.assertFalse(non_coffee["saved"])
            self.assertTrue(non_coffee["rejected_as_non_coffee"])
            self.assertEqual(len(store.list_records()), before_non_coffee)


class TestModularIngestionHTTPAPI(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
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

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        for k, v in self._orig.items():
            setattr(app_module, k, v)
        self._tmpdir.cleanup()

    def _request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        raw = resp.read()
        resp_headers = dict(resp.getheaders())
        conn.close()
        return resp.status, resp_headers, raw

    def test_multipart_upload_audio_ingest_and_range_playback(self):
        payload_bytes = b"0123456789abcdefghijklmnopqrstuvwxyz"
        boundary, body = _build_multipart_body(
            {
                "source_type": "iphone",
                "source_device": "iPhone 16 Pro",
                "record_intent": "auto",
                "transcript": "今天用耶加雪菲水洗浅烘，称重18克，Niche Zero刻度15，意式浓缩9bar萃取29秒，出液36克。",
            },
            file_field=("file", "iphone_brew.m4a", "audio/mp4", payload_bytes),
        )
        with mock.patch.object(
            app_module.vision_engine,
            "extract_audio_and_transcribe_segments",
            return_value=("", []),
        ):
            status, _, raw = self._request(
                "POST",
                "/api/ingest/upload",
                body=body,
                headers={
                    "Content-Type": f"multipart/form-data; boundary={boundary}",
                    "Content-Length": str(len(body)),
                },
            )
        self.assertEqual(status, 200)
        data = json.loads(raw.decode("utf-8"))
        self.assertTrue(data["ok"])
        self.assertEqual(data["record_type"], "brew_report")
        self.assertEqual(data["record"]["camera_device"], "iPhone 16 Pro")
        self.assertEqual(data["record"]["source_type"], "iphone")
        self.assertEqual(data["record"]["media_kind"], "audio")
        self.assertTrue(data["media_url"].startswith("/api/media/file?path="))

        # Verify Range playback on uploaded audio file
        r_status, r_hdrs, r_raw = self._request(
            "GET",
            data["media_url"],
            headers={"Range": "bytes=0-9"},
        )
        self.assertEqual(r_status, 206)
        self.assertEqual(r_raw, b"0123456789")
        self.assertEqual(r_hdrs.get("Content-Range"), f"bytes 0-9/{len(payload_bytes)}")

    def test_standalone_recognize_then_generate_equipment_profile_via_http(self):
        # Step 1: Standalone recognition endpoint (no record saved)
        before = len(app_module.store.list_records())
        rec_body = json.dumps({
            "source_device": "iPad Air",
            "transcript": "介绍一下新买的格米莱3828咖啡机自带豆仓，还有轰炸机压粉锤和布粉器，这就是我的一整套器具。",
        }).encode("utf-8")
        st1, _, raw1 = self._request(
            "POST",
            "/api/recognize/media",
            body=rec_body,
            headers={"Content-Type": "application/json", "Content-Length": str(len(rec_body))},
        )
        self.assertEqual(st1, 200)
        d1 = json.loads(raw1.decode("utf-8"))
        self.assertTrue(d1["ok"])
        self.assertEqual(len(app_module.store.list_records()), before)

        # Step 2: Standalone report generation endpoint
        gen_body = json.dumps({
            "transcript": d1["transcript"],
            "source_device": "iPad Air",
            "source_type": "ipad",
            "record_intent": "auto",
            "save": True,
            "notify": False,
        }).encode("utf-8")
        st2, _, raw2 = self._request(
            "POST",
            "/api/reports/generate",
            body=gen_body,
            headers={"Content-Type": "application/json", "Content-Length": str(len(gen_body))},
        )
        self.assertEqual(st2, 200)
        d2 = json.loads(raw2.decode("utf-8"))
        self.assertTrue(d2["ok"])
        self.assertEqual(d2["record_type"], "equipment_profile")
        self.assertEqual(d2["record"]["camera_device"], "iPad Air")
        self.assertEqual(len(app_module.store.list_records()), before + 1)
        eq_store = app_module.bean_manager.load_all()["equipment"]
        self.assertIn("格米莱", eq_store.get("espresso_machine", ""))


if __name__ == "__main__":
    unittest.main()
