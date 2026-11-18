import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

from core import multimodal_vision as vision
from core.camera_sta_bridge import CameraInternalBridge
from core.notifier import NotificationManager
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager


class MultimodalTests(unittest.TestCase):
    def temp_path(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Path(directory.name)

    def test_stage_windows_follow_speech_and_leave_room_before_stop(self):
        windows = vision._compute_stage_time_windows(
            100,
            [{"text": "称豆", "timestamp_s": 21}, {"text": "9 bar", "timestamp_s": 62}],
            [{"text": "研磨刻度", "timestamp_s": 41}, {"text": "停止录像", "timestamp_s": 96}],
        )
        assert windows["scale_dose"] == (19.5, 22.5, 21, True)
        assert windows["grinder_dial"] == (39.5, 42.5, 41, True)
        assert windows["pressure_crema"] == (60.5, 63.5, 62, True)
        start, end, center, anchored = windows["yield_timer"]
        self.assertEqual((start, end, anchored), (93, 95.6, True))
        self.assertAlmostEqual(center, 94.3)
        assert vision._compute_stage_time_windows(100, [], [])["scale_dose"] == (6, 26, 15, False)


    def test_candidate_ranking_rewards_edges_exposure_and_stage_ocr(self):
        flat = vision._frame_quality(bytes([128] * 4096))
        detailed = vision._frame_quality(bytes(76 if x % 4 < 2 else 180 for x in range(4096)))
        dark = vision._frame_quality(bytes(0 if x % 4 < 2 else 12 for x in range(4096)))
        assert detailed > flat and detailed > dark
        candidates = [
            {"timestamp_s": 4, "sharpness_score": 30, "ocr_texts": ["2026"]},
            {"timestamp_s": 5, "sharpness_score": 27, "ocr_texts": ["18.5 g"]},
            {"timestamp_s": 6, "sharpness_score": 5, "ocr_texts": []},
        ]
        assert vision._select_candidate("scale_dose", candidates, 4)["timestamp_s"] == 5


    def test_offline_ocr_enriches_report_and_overrides_hints(self):
        tmp_path = self.temp_path()
        engine = vision.MultimodalVisionEngine(str(tmp_path))
        frames = []
        for (_, stage, label), ocr in zip(vision.KEYFRAME_PLAN, [
            ["花魁", "18.5", "g"], ["DF64 Gen 2", "刻度 14.5"], ["9.2 bar", "93 °C"], ["0:28", "36.1g"]
        ]):
            frames.append(dict(stage=label, stage_key=stage, timestamp_s=4.2, percentage=16,
                               selection_method="speech_anchor+vision_score", sharpness_score=92,
                               candidates_evaluated=4, ocr_texts=ocr))
        with patch.object(engine, "extract_video_metadata_and_frames", return_value=dict(
            keyframes=frames, is_remote_url=False, extracted_real_frames=False, source_type="local_file",
            duration_s=29)), patch.dict(os.environ, {"GEMINI_API_KEY": "", "OPENAI_API_KEY": ""}):
            (tmp_path / "bean_library.json").write_text(
                '{"beans":[{"full_name":"埃塞花魁 日晒","short_aliases":["花魁"]}]}', encoding="utf-8")
            analysis = engine.analyze_video_keyframes("brew.MP4", hint_overrides={"bean_weight_g": 20})
        assert analysis["visual_fields"] == dict(bean_name="埃塞花魁 日晒", bean_weight_g=18.5,
            grinder_model="DF64", grind_setting="刻度 14.5", pressure_bar=9.2, water_temp_c=93,
            yield_g=36.1, extraction_time_s=28)
        assert "候选 4 帧" in analysis["frame_observations"][0]["visual_description"]


    def test_native_camera_fixture(self):
        clip = Path(os.environ.get("POCKET_COFFEE_TEST_MP4", str(Path(__file__).resolve().parents[1] /
            "data/media_cache/DJI_20261118174915_0044_D.MP4")))
        if sys.platform != "darwin" or not shutil.which("swift") or not clip.is_file():
            self.skipTest("Requires macOS and the cached DJI camera MP4")
        tmp_path = self.temp_path()
        data_dir = str(tmp_path)
        manager = VoiceWakeupSessionManager(
            CoffeeStore(data_dir), CameraInternalBridge(data_dir), NotificationManager(data_dir)
        )
        with patch.dict(os.environ, {"GEMINI_API_KEY": "", "OPENAI_API_KEY": ""}), \
                patch.object(manager.notifier, "notify_brew_record", return_value={}):
            result = manager.stop_and_process(video_path=str(clip), media_finalized=True)
        meta = result["vision_analysis"]["video_metadata"]
        self.assertEqual(len(result["record"]["keyframes"]), 4)
        assert meta["frame_backend"] == "avfoundation"
        assert meta["extracted_frame_count"] == 4
        for frame in meta["keyframes"]:
            assert frame["selection_method"] == "smart_window+vision_score"
            assert frame["candidates_evaluated"] >= 3
            assert frame["sharpness_score"] > 0
            assert isinstance(frame["ocr_texts"], list)
            assert Path(frame["image_path"]).read_bytes().startswith(b"\xff\xd8")
