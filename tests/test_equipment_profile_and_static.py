import os
import tempfile
import unittest

from core.analyzer import (
    extract_parameters_from_transcript,
    is_equipment_introduction,
    relabel_keyframes_for_equipment_profile,
)
from core.bean_equipment_store import BeanAndEquipmentManager


PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class TestEquipmentProfileClassification(unittest.TestCase):
    def test_equipment_intro_classified_as_equipment_profile(self):
        transcript = (
            "今天先介绍一下我家里做咖啡的器具，来看看我们的咖啡机格米莱3828自带豆仓，"
            "还有轰炸机自动回弹压粉锤、四桨布粉器、接粉环和布粉针，这就是我们这一整套的咖啡制作的工具。"
        )
        rec = extract_parameters_from_transcript(transcript)
        self.assertEqual(rec.record_type, "equipment_profile")
        self.assertEqual(rec.status, "complete")
        self.assertEqual(rec.missing_fields, [])
        self.assertGreaterEqual(len(rec.equipment_items), 3)
        self.assertTrue(is_equipment_introduction(transcript, rec))

        kfs = [
            {"stage": "P1 称豆", "extracted": True, "image_path": "/tmp/a.jpg"},
            {"stage": "P2 刻度", "extracted": True, "image_path": "/tmp/b.jpg"},
        ]
        relabeled = relabel_keyframes_for_equipment_profile(kfs, rec.equipment_items)
        self.assertTrue(relabeled[0]["preset_badge"].startswith("E1"))
        self.assertTrue(relabeled[1]["preset_badge"].startswith("E2"))

    def test_actual_brew_stays_brew_report(self):
        transcript = "使用格米莱3828自带磨豆机，称豆18克，研磨刻度12，9bar萃取28秒，出液36克。"
        rec = extract_parameters_from_transcript(transcript)
        self.assertEqual(rec.record_type, "brew_report")
        self.assertEqual(rec.bean_weight_g, 18.0)
        self.assertEqual(rec.yield_g, 36.0)
        self.assertFalse(is_equipment_introduction(transcript, rec))

    def test_update_equipment_from_intro_merges_without_duplicates(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            mgr = BeanAndEquipmentManager(tmpdir)
            items = [
                {"id": "eq-gemilai-g3828a", "name": "格米莱 G3828A", "category": "主力咖啡机"},
                {"id": "eq-mhw-tamper", "name": "轰炸机压粉锤", "category": "压粉器具"},
            ]
            eq1 = mgr.update_equipment_from_intro(
                equipment_items=items,
                grinder_type="独立磨豆机",
                grinder_model="Niche Zero",
                espresso_machine="格米莱 G3828A",
            )
            self.assertEqual(eq1["espresso_machine"], "格米莱 G3828A")
            self.assertEqual(eq1["grinder_model"], "Niche Zero")

            # Second update with same id should merge rather than duplicate
            eq2 = mgr.update_equipment_from_intro(
                equipment_items=[{"id": "eq-mhw-tamper", "name": "轰炸机压粉锤", "spec": "58.35mm"}],
                espresso_machine="格米莱 G3828A",
            )
            tamper_entries = [a for a in eq2["accessories"] if a.get("id") == "eq-mhw-tamper"]
            self.assertEqual(len(tamper_entries), 1)
            self.assertEqual(tamper_entries[0]["spec"], "58.35mm")


class TestModularStaticAssets(unittest.TestCase):
    def test_index_html_is_modular_and_assets_exist(self):
        index_path = os.path.join(PROJECT_ROOT, "static", "index.html")
        with open(index_path, "r", encoding="utf-8") as f:
            html = f.read()
        self.assertLess(len(html.splitlines()), 400)
        self.assertIn('href="/css/styles.css"', html)
        self.assertIn('role="status"', html)
        for rel in [
            "static/css/styles.css",
            "static/js/app.js",
            "static/js/equipment.js",
            "static/js/camera.js",
            "static/js/share.js",
        ]:
            full = os.path.join(PROJECT_ROOT, rel)
            self.assertTrue(os.path.isfile(full), f"Missing split static asset: {rel}")
            self.assertGreater(os.path.getsize(full), 500)

        with open(os.path.join(PROJECT_ROOT, "static", "js", "share.js"), "r", encoding="utf-8") as f:
            share_js = f.read()
        for fn in ("quickSharePlatform", "nativeSystemShare", "copyPosterImageToClipboard", "copyTextWithFallback"):
            self.assertIn(f"function {fn}", share_js)


if __name__ == "__main__":
    unittest.main()
