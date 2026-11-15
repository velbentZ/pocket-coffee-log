"""
Personal Coffee Bean Inventory, Default Equipment Preset & Subjective Feedback Loop (`core/bean_equipment_store.py`).

Implements:
1. **Coffee Bean Library (`BeanEntry`)**:
   - Pre-stores user's favorite coffee beans with shorthand aliases (e.g., saying "今天用花魁" or "用瑰夏"
     automatically fills in full origin, estate, process, roast level, recommended grind setting, and target ratio).
2. **Default Equipment Presets (`EquipmentPreset`)**:
   - Stores user's primary independent grinder (e.g., Niche Zero / DF64 / Weber EG-1) and built-in machine grinder
     (e.g., Breville 878), plus espresso machine defaults (water temperature 93°C, pressure 9.0 bar).
   - If the user doesn't mention which grinder they used during a busy morning brew, automatically fills in
     the default grinder (or flags it with high-confidence preset provenance).
3. **Subjective Taste Feedback Loop (`TasteFeedback`)**:
   - Allows the user to rate the finished cup (1-5 stars) and tag subjective impressions:
     - `too_sour` (偏酸/尖酸) -> Next brew advisor recommends grinding 0.5-1.0 step finer or raising water temp +1°C.
     - `too_bitter` (偏苦/干涩) -> Next brew advisor recommends grinding 0.5-1.0 step coarser or shortening yield by 2-3g.
     - `watery` (偏淡/醇厚度不足) -> Next brew advisor recommends increasing dose +0.5g or tightening ratio.
     - `balanced_sweet` (酸甜平衡/完美命中) -> Locks current grind & ratio as the Golden Recipe for this bean!
"""

from dataclasses import dataclass, field, asdict
from datetime import datetime
import json
import os
from typing import Any, Dict, List, Optional


@dataclass
class BeanEntry:
    bean_id: str
    short_aliases: List[str]          # e.g., ["花魁", "花魁7.0", "埃塞花魁"]
    full_name: str                    # e.g., "埃塞俄比亚 罕贝拉 花魁 7.0 日晒"
    origin: str                       # "埃塞俄比亚 · 古吉罕贝拉"
    process: str                      # "日晒处理 (Natural)"
    roast_level: str                  # "中浅烘焙"
    flavor_tags: List[str]            # ["佛手柑", "百香果", "草莓果酱", "奶油太妃糖"]
    recommended_grind: str            # "刻度 14.5 格"
    recommended_dose_g: float = 18.5
    recommended_ratio: str = "1:2.0"
    golden_recipe_note: str = "93°C / 9.2 bar / 29s 出液 37g（甜感最佳）"
    remaining_weight_g: float = 220.0


@dataclass
class EquipmentProfile:
    default_grinder_type: str = "额外独立磨豆机"
    default_grinder_model: str = "Niche Zero (63mm 锥刀)"
    secondary_grinder_type: str = "咖啡机自带磨豆机"
    secondary_grinder_model: str = "Breville 铂富内置锥刀磨豆机"
    espresso_machine: str = "Breville / 变压意式咖啡机"
    default_water_temp_c: float = 93.0
    default_pressure_bar: float = 9.0
    auto_fill_default_grinder: bool = True
    single_camera_auto_switch: bool = True  # Automatically binds whichever camera (Pocket 3 or Pocket 4 Pro) is active


class BeanAndEquipmentManager:
    def __init__(self, data_dir: str) -> None:
        self.data_dir = data_dir
        self.file_path = os.path.join(data_dir, "bean_equipment_library.json")
        self._ensure_seeded()

    def _ensure_seeded(self) -> None:
        os.makedirs(self.data_dir, exist_ok=True)
        if not os.path.exists(self.file_path):
            default_beans = [
                asdict(
                    BeanEntry(
                        bean_id="bean-huakui",
                        short_aliases=["花魁", "花魁7.0", "罕贝拉"],
                        full_name="埃塞俄比亚 罕贝拉 花魁 7.0 日晒",
                        origin="埃塞俄比亚 · 古吉罕贝拉",
                        process="日晒 (Natural)",
                        roast_level="中浅烘焙",
                        flavor_tags=["佛手柑", "热带百香果", "草莓果酱", "奶油太妃糖"],
                        recommended_grind="刻度 14.5 格",
                        recommended_dose_g=18.5,
                        recommended_ratio="1:2.0",
                        golden_recipe_note="Niche 刻度 14.5 | 18.5g -> 37g | 29s @ 9.2 bar",
                        remaining_weight_g=185.0,
                    )
                ),
                asdict(
                    BeanEntry(
                        bean_id="bean-geisha",
                        short_aliases=["瑰夏", "绿标瑰夏", "红标瑰夏", "翡翠庄园"],
                        full_name="巴拿马 翡翠庄园 绿标瑰夏 水洗",
                        origin="巴拿马 · 波奎特 (Boquete)",
                        process="水洗 (Washed)",
                        roast_level="浅度烘焙",
                        flavor_tags=["茉莉白花", "佛手柑", "水蜜桃汁", "蜂蜜红茶尾韵"],
                        recommended_grind="刻度 13.5 格 (意式) / 刻度 58 格 (冷萃)",
                        recommended_dose_g=18.0,
                        recommended_ratio="1:2.2",
                        golden_recipe_note="意式 93°C 18g->40g 27s | 冷萃 45g->405ml 12h",
                        remaining_weight_g=140.0,
                    )
                ),
                asdict(
                    BeanEntry(
                        bean_id="bean-paraiso",
                        short_aliases=["天堂庄园", "哥伦比亚", "双重厌氧"],
                        full_name="哥伦比亚 考卡山谷 天堂庄园 双重厌氧水洗",
                        origin="哥伦比亚 · 考卡 (Cauca)",
                        process="双重厌氧水洗",
                        roast_level="中浅烘焙",
                        flavor_tags=["水蜜桃酸奶", "玫瑰花露", "白桃乌龙", "丝滑奶油"],
                        recommended_grind="刻度 14.0 格",
                        recommended_dose_g=18.0,
                        recommended_ratio="1:1.9",
                        golden_recipe_note="搭配冰博克制作 Dirty 绝佳，刻度 14.0 流速最稳",
                        remaining_weight_g=210.0,
                    )
                ),
            ]
            payload = {
                "equipment": asdict(EquipmentProfile()),
                "beans": default_beans,
                "taste_feedback_history": [],
            }
            with open(self.file_path, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=2)

    def load_all(self) -> Dict[str, Any]:
        with open(self.file_path, "r", encoding="utf-8") as f:
            return json.load(f)

    def save_all(self, data: Dict[str, Any]) -> None:
        with open(self.file_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def match_bean_by_text(self, text: str) -> Optional[Dict[str, Any]]:
        """
        Matches spoken shorthand (e.g. '今天用花魁' or '冲一杯瑰夏') against the user's Bean Library
        and returns the full bean profile so the user doesn't have to recite origin/process/roast every time.
        """
        data = self.load_all()
        for bean in data.get("beans", []):
            for alias in bean.get("short_aliases", []):
                if alias and alias.lower() in text.lower():
                    return bean
            if bean.get("full_name", "") and bean["full_name"].lower() in text.lower():
                return bean
        return None

    def add_or_update_bean(self, bean_dict: Dict[str, Any]) -> Dict[str, Any]:
        data = self.load_all()
        beans = data.get("beans", [])
        bean_id = bean_dict.get("bean_id") or f"bean-{datetime.now().strftime('%H%M%S')}"
        bean_dict["bean_id"] = bean_id
        if isinstance(bean_dict.get("short_aliases"), str):
            bean_dict["short_aliases"] = [x.strip() for x in bean_dict["short_aliases"].split(",") if x.strip()]
        if isinstance(bean_dict.get("flavor_tags"), str):
            bean_dict["flavor_tags"] = [x.strip() for x in bean_dict["flavor_tags"].split(",") if x.strip()]

        replaced = False
        for i, b in enumerate(beans):
            if b.get("bean_id") == bean_id:
                beans[i] = {**b, **bean_dict}
                replaced = True
                break
        if not replaced:
            beans.insert(0, bean_dict)
        data["beans"] = beans
        self.save_all(data)
        return bean_dict

    def apply_taste_feedback(
        self,
        record_dict: Dict[str, Any],
        rating: int,
        taste_tag: str,
        user_note: str = "",
    ) -> Dict[str, Any]:
        """
        Incorporates user's post-brew subjective tasting score & feedback tag
        (`too_sour`, `too_bitter`, `watery`, `balanced_sweet`) to generate adaptive
        barista calibration advice and update the Bean Library's Golden Recipe.
        """
        data = self.load_all()
        grind_cur = record_dict.get("grind_setting") or "当前刻度"
        weight_cur = record_dict.get("bean_weight_g") or 18.0
        yield_cur = record_dict.get("yield_g") or 36.0

        calibration_advice = ""
        if taste_tag == "too_sour":
            calibration_advice = (
                f"🎯【主观品鉴校准：偏酸/尖酸 ({rating}★)】已记录！说明前段酸性物质析出占比偏高、甜感段未充分萃出。"
                f"下次使用同款豆时，系统将提醒您将 {grind_cur} 往细微调 0.5~0.8 格，或保持粉量 {weight_cur}g 将出液量增加 3g 至 {round(float(yield_cur) + 3, 1)}g，水温提高 1°C。"
            )
        elif taste_tag == "too_bitter":
            calibration_advice = (
                f"🎯【主观品鉴校准：偏苦/尾段干涩 ({rating}★)】已记录！说明后段过萃或细粉通道导致木质苦味析出。"
                f"下次使用同款豆时，建议将 {grind_cur} 往粗微调 0.5~1.0 格，或在 {round(float(yield_cur) - 3, 1)}g 处提前截流断液。"
            )
        elif taste_tag == "watery":
            calibration_advice = (
                f"🎯【主观品鉴校准：醇厚度偏弱/偏水 ({rating}★)】已记录！建议下次将粉量从 {weight_cur}g 提升至 {round(float(weight_cur) + 0.5, 1)}g，"
                f"并将粉液比收紧至 1:1.85，提升油脂包裹感。"
            )
        else:
            calibration_advice = (
                f"🏆【主观品鉴校准：酸甜平衡·黄金配方锁定 ({rating}★)】太棒了！已将本次参数（{weight_cur}g 粉 -> {yield_cur}g 液，{grind_cur}）"
                f"写入您的个人咖啡豆库黄金配方！"
            )
            # Update bean golden recipe if matched
            bean_name = record_dict.get("bean_name") or ""
            for b in data.get("beans", []):
                if any(a in bean_name for a in b.get("short_aliases", [])) or b.get("full_name") == bean_name:
                    b["recommended_grind"] = grind_cur
                    b["recommended_dose_g"] = weight_cur
                    b["golden_recipe_note"] = (
                        f"★黄金锁定({rating}分): {weight_cur}g -> {yield_cur}g ({record_dict.get('brew_ratio', '1:2')}) | "
                        f"{grind_cur} | {record_dict.get('extraction_time_s', 28)}s @ {record_dict.get('pressure_bar', 9)} bar"
                    )

        feedback_entry = {
            "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "record_id": record_dict.get("id"),
            "bean_name": record_dict.get("bean_name"),
            "rating": rating,
            "taste_tag": taste_tag,
            "user_note": user_note,
            "calibration_advice": calibration_advice,
        }
        data.setdefault("taste_feedback_history", []).insert(0, feedback_entry)
        data["taste_feedback_history"] = data["taste_feedback_history"][:50]
        self.save_all(data)
        return feedback_entry
