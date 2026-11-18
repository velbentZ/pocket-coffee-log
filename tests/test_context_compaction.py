"""Automated tests for Lossless Context Compaction, Provenance, and Project Memory."""

import os
import tempfile
import unittest

from core.context_engine import ProjectMemoryManager, SessionContextCompactor
from core.registry import EventBus, ModuleRegistry


class TestContextCompactionAndModularity(unittest.TestCase):
    def test_lossless_multi_turn_compaction_and_self_correction(self) -> None:
        compactor = SessionContextCompactor()
        utterances = [
            {
                "text": "我要开始制作咖啡，今天咖啡豆用的是埃塞俄比亚花魁7.0日晒中浅烘，豆子称重 18 克",
                "source": "voice_utterance",
                "timestamp": "09:40:01",
            },
            {
                "text": "不对，今天豆子称重是 18.5 克，用的是额外独立磨豆机 Niche Zero，研磨度刻度 14.5 格",
                "source": "voice_utterance",
                "timestamp": "09:40:15",
            },
            {
                "text": "今天做的是意式浓缩，水温 93 度，萃取压力 9.2 bar，萃取时间 29 秒，出液 37 克",
                "source": "video_frame_ocr",
                "timestamp": "09:41:10",
            },
        ]

        ctx = compactor.compact_utterances("sess-test-01", utterances, camera_device="DJI Osmo Pocket 4 Pro")

        # 1. Verify self-correction resolved to 18.5g while preserving revision history (18.0 -> 18.5)
        self.assertEqual(ctx.canonical_parameters["bean_weight_g"], 18.5)
        self.assertTrue(any(r["field"] == "bean_weight_g" and r["old_value"] == 18.0 and r["new_value"] == 18.5 for r in ctx.revision_history))

        # 2. Verify zero missing fields and 100% invariant retention
        self.assertEqual(ctx.missing_fields, [])
        self.assertTrue(ctx.invariants_verified)
        self.assertEqual(ctx.canonical_parameters["brew_ratio"], "1:2.0")
        self.assertEqual(ctx.provenance_map["pressure_bar"]["source"], "video_frame_ocr")
        self.assertTrue(len(ctx.checksum_sha256) == 16)

    def test_project_memory_snapshot_generation(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mgr = ProjectMemoryManager(tmpdir)
            snap = mgr.refresh_snapshot()
            self.assertEqual(snap["schema_version"], "3.0.0")
            self.assertTrue(os.path.exists(mgr.snapshot_json_path))
            self.assertTrue(os.path.exists(mgr.snapshot_md_path))
            self.assertTrue(len(snap["hard_invariants"]) >= 5)

    def test_event_bus_and_module_registry(self) -> None:
        bus = EventBus()
        received = []
        bus.subscribe("coffee.brewed", lambda p: received.append(p["id"]))
        count = bus.publish("coffee.brewed", {"id": "brew-123"})
        self.assertEqual(count, 1)
        self.assertEqual(received, ["brew-123"])

        reg = ModuleRegistry()
        reg.register("camera_driver", "mock_sta", lambda: "ok", {"sta": True})
        self.assertIsNotNone(reg.get("camera_driver", "mock_sta"))
        self.assertIn("mock_sta", reg.summary()["camera_driver"])

    def test_bean_library_shorthand_and_taste_feedback_loop(self) -> None:
        from core.bean_equipment_store import BeanAndEquipmentManager
        from core.camera_sta_bridge import CameraInternalBridge
        from core.notifier import NotificationManager
        from core.store import CoffeeStore
        from daemon.voice_session import VoiceWakeupSessionManager

        with tempfile.TemporaryDirectory() as tmpdir:
            store = CoffeeStore(tmpdir)
            bridge = CameraInternalBridge(tmpdir)
            notifier = NotificationManager(tmpdir)
            notifier.save_config({"enable_macos_banner": False})
            vm = VoiceWakeupSessionManager(store, bridge, notifier)

            # User only says shorthand "今天用花魁" without mentioning grinder model or roast level
            res = vm.stop_and_process(
                reason="测试豆库简称匹配与默认磨豆机补全",
                override_transcript="我要开始制作咖啡。今天用花魁，称重 18.5 克，刻度 14.5 格，做意式浓缩，9.2 bar 萃取 29 秒，出液 37 克。制作完成。",
            )
            rec_dict = res["record"]
            self.assertIn("罕贝拉 花魁 7.0", rec_dict["bean_name"])
            self.assertEqual(rec_dict["bean_roast"], "中浅烘焙")
            self.assertEqual(rec_dict["grinder_type"], "额外独立磨豆机")
            self.assertIn("Niche Zero", rec_dict["grinder_model"])
            self.assertEqual(rec_dict["status"], "complete")

            # Apply subjective taste feedback ("too_sour") and verify adaptive calibration advice
            bean_mgr = BeanAndEquipmentManager(tmpdir)
            fb = bean_mgr.apply_taste_feedback(rec_dict, rating=4, taste_tag="too_sour", user_note="入口稍微有一点点尖酸")
            self.assertIn("往细微调", fb["calibration_advice"])


if __name__ == "__main__":
    unittest.main()
