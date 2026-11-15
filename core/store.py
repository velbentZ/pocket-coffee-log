"""Persistent storage and initial sample coffee records for Pocket Coffee Log."""

import json
import os
from typing import Dict, List, Optional

from core.analyzer import extract_parameters_from_transcript
from core.models import CoffeeRecord


class CoffeeStore:
    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        self.records_path = os.path.join(data_dir, "coffee_records.json")
        self._ensure_seeded()

    def _ensure_seeded(self) -> None:
        os.makedirs(self.data_dir, exist_ok=True)
        if not os.path.exists(self.records_path):
            samples = self._build_initial_samples()
            self._save_raw([r.to_dict() for r in samples])

    def _build_initial_samples(self) -> List[CoffeeRecord]:
        # 1. Complete SOE Espresso recorded by Pocket 4 Pro over LAN STA
        r1 = extract_parameters_from_transcript(
            transcript=(
                "我要开始制作咖啡。今天咖啡豆用的是埃塞俄比亚花魁7.0日晒中浅烘，咖啡豆称重是18.5克，"
                "用的是额外独立磨豆机 Niche Zero，研磨度调到刻度 14.5 格。"
                "今天做的是 SOE 单一产地意式浓缩，水温 93 度，萃取压力稳定在 9.2 bar，"
                "萃取时间用了 29 秒，最后出液量是 37 克。好了，咖啡制作完成。"
            ),
            camera_device="DJI Osmo Pocket 4 Pro",
            video_path="/storage/sdcard0/DCIM/DJI_001/DJI_20261115_094210_001.MP4",
        )
        r1.id = "brew-20261115-094210-p4p"
        r1.created_at = "2026-11-15 09:42:10"
        r1.notification_sent = True

        # 2. Incomplete Espresso record missing Grind Setting & Pressure (to demonstrate automatic missing-field alert & mobile supplement)
        r2 = extract_parameters_from_transcript(
            transcript=(
                "开始做咖啡。这杯咖啡豆用的是哥伦比亚天堂庄园双重厌氧中浅烘，豆子称重 18 克，"
                "用的是咖啡机自带磨豆机铂富内置磨，做一杯意式浓缩冰拿铁，"
                "萃取时间 27 秒，出液是 35 克。制作结束。"
            ),
            camera_device="DJI Osmo Pocket 3",
            video_path="/storage/sdcard0/DCIM/DJI_001/DJI_20261115_095012_002.MP4",
        )
        r2.id = "brew-20261115-095012-p3"
        r2.created_at = "2026-11-15 09:50:12"
        r2.notification_sent = True

        # 3. Complete Cold Brew record recorded by Pocket 4 Pro
        r3 = extract_parameters_from_transcript(
            transcript=(
                "我要开始制作咖啡。今天做一壶冷萃咖啡，咖啡豆用的是巴拿马翡翠庄园绿标瑰夏浅烘，"
                "咖啡豆称重 45 克，用的是额外独立磨豆机 DF64，研磨度调到刻度 58 格，"
                "注水出液量是 405 毫升，冰箱低温萃取时间 12 小时。录制结束。"
            ),
            camera_device="DJI Osmo Pocket 4 Pro",
            video_path="/storage/sdcard0/DCIM/DJI_001/DJI_20261114_211500_009.MP4",
        )
        r3.id = "brew-20261114-211500-cb"
        r3.created_at = "2026-11-14 21:15:00"
        r3.notification_sent = True

        return [r1, r2, r3]

    def _load_raw(self) -> List[Dict]:
        try:
            with open(self.records_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return []

    def _save_raw(self, items: List[Dict]) -> None:
        with open(self.records_path, "w", encoding="utf-8") as f:
            json.dump(items, f, ensure_ascii=False, indent=2)

    def list_records(self) -> List[CoffeeRecord]:
        return [CoffeeRecord.from_dict(d) for d in self._load_raw()]

    def get_record(self, record_id: str) -> Optional[CoffeeRecord]:
        for d in self._load_raw():
            if d.get("id") == record_id:
                return CoffeeRecord.from_dict(d)
        return None

    def save_record(self, record: CoffeeRecord) -> CoffeeRecord:
        items = self._load_raw()
        replaced = False
        for idx, item in enumerate(items):
            if item.get("id") == record.id:
                items[idx] = record.to_dict()
                replaced = True
                break
        if not replaced:
            items.insert(0, record.to_dict())
        self._save_raw(items)
        return record
