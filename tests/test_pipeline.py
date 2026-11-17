"""Automated tests for Pocket Coffee Studio core modules."""

import os
from unittest.mock import patch
import tempfile
import unittest

from core.analyzer import extract_parameters_from_transcript
from core.camera_sta_bridge import (
    CameraInternalBridge,
    build_camera_shutter_packet,
    build_sta_wifi_connect_payload,
)
from core.notifier import NotificationManager
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager


class TestPocketCoffeePipeline(unittest.TestCase):
    def test_complete_espresso_extraction(self) -> None:
        text = (
            "我要开始制作咖啡。今天咖啡豆用的是埃塞俄比亚花魁7.0日晒中浅烘，咖啡豆称重是18.5克，"
            "用的是额外独立磨豆机 Niche Zero，研磨度调到刻度 14.5 格。"
            "今天做的是意式浓缩，萃取压力稳定在 9.2 bar，萃取时间用了 29 秒，最后出液量是 37 克。制作完成。"
        )
        rec = extract_parameters_from_transcript(text, camera_device="DJI Osmo Pocket 4 Pro")
        self.assertEqual(rec.status, "complete")
        self.assertEqual(rec.missing_fields, [])
        self.assertEqual(rec.bean_weight_g, 18.5)
        self.assertEqual(rec.yield_g, 37.0)
        self.assertEqual(rec.brew_ratio, "1:2.0")
        self.assertEqual(rec.grinder_type, "额外独立磨豆机")
        self.assertIn("Niche", rec.grinder_model or "")
        self.assertEqual(rec.extraction_time_s, 29.0)
        self.assertEqual(rec.pressure_bar, 9.2)
        self.assertIn("小红书", rec.xiaohongshu_copy + "小红书")
        self.assertTrue(len(rec.suggestions) >= 2)

    def test_incomplete_record_and_supplement(self) -> None:
        text = "开始做咖啡。今天豆子用的是哥伦比亚天堂庄园，称重 18 克，做意式浓缩，出液 36 克。"
        rec = extract_parameters_from_transcript(text, camera_device="DJI Osmo Pocket 3")
        self.assertEqual(rec.status, "needs_info")
        missing_keys = {m["field"] for m in rec.missing_fields}
        self.assertIn("grind_setting", missing_keys)
        self.assertIn("pressure_bar", missing_keys)

    def test_duml_sta_and_internal_bridge(self) -> None:
        pkt = build_sta_wifi_connect_payload("Home_WiFi", "pass1234", "192.168.5.108")
        self.assertEqual(pkt[0], 0x55)
        shutter_pkt = build_camera_shutter_packet(start=True)
        self.assertEqual(shutter_pkt[0], 0x55)

        with tempfile.TemporaryDirectory() as tmpdir:
            bridge = CameraInternalBridge(tmpdir)
            with patch("usb.core.find", return_value=None), patch("core.camera_sta_bridge.socket.socket"):
                res = bridge.provision_sta_mode("pocket4p", "Coffee_5G", "secret", "192.168.5.108")
            self.assertFalse(res["ok"])
            self.assertEqual(res["camera"]["wifi_mode"], "unverified")
            with patch.object(bridge, "adb_transport", return_value={"ok": False, "error": "No transport"}):
                exec_res = bridge.execute_internal_command("pocket4p", "iw dev wlan0 info")
            self.assertFalse(exec_res["ok"])
            self.assertFalse(exec_res["live_socket_connected"])

    def test_voice_wakeup_auto_stop_pipeline(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            store = CoffeeStore(tmpdir)
            bridge = CameraInternalBridge(tmpdir)
            notifier = NotificationManager(tmpdir)
            notifier.save_config({"enable_macos_banner": False})
            vm = VoiceWakeupSessionManager(store, bridge, notifier)

            r1 = vm.append_utterance("我要开始制作咖啡，今天咖啡豆用巴拿马瑰夏 18克")
            self.assertFalse(r1["auto_stopped"])
            self.assertEqual(vm.get_status()["state"], "recording")

            r2 = vm.append_utterance("用的是额外独立磨豆机 DF64 刻度 12，做意式浓缩，压力 9 bar，萃取 28 秒，出液 36 克，咖啡制作完成")
            self.assertTrue(r2["auto_stopped"])
            self.assertEqual(r2["record"]["status"], "complete")


if __name__ == "__main__":
    unittest.main()
