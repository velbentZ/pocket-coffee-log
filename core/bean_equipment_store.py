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
from datetime import date, datetime, timedelta
import hashlib
import json
import os
import re
from typing import Any, Dict, List, Optional, Tuple


ORIGIN_RULES: List[Tuple[List[str], str]] = [
    (["巴拿马", "翡翠庄园", "Panama", "Esmeralda"], "巴拿马 · 波奎特/翡翠庄园"),
    (["罕贝拉", "Hambela"], "埃塞俄比亚 · 古吉罕贝拉"),
    (["耶加雪菲", "Yirgacheffe"], "埃塞俄比亚 · 耶加雪菲"),
    (["西达摩", "Sidamo"], "埃塞俄比亚 · 西达摩"),
    (["埃塞俄比亚", "埃塞", "Ethiopia"], "埃塞俄比亚"),
    (["天堂庄园", "考卡", "Cauca", "Paraiso"], "哥伦比亚 · 考卡 (Cauca)"),
    (["慧兰", "Huila"], "哥伦比亚 · 慧兰 (Huila)"),
    (["哥伦比亚", "Colombia"], "哥伦比亚"),
    (["肯尼亚", "Kenya"], "肯尼亚"),
    (["洪都拉斯", "雪莉", "Honduras"], "洪都拉斯"),
    (["哥斯达黎加", "Costa Rica"], "哥斯达黎加"),
    (["危地马拉", "安提瓜", "Guatemala"], "危地马拉"),
    (["云南", "保山", "普洱", "孟连", "Yunnan"], "中国 · 云南"),
    (["巴西", "Brazil"], "巴西"),
    (["曼特宁", "印尼", "苏门答腊", "Sumatra", "Indonesia"], "印度尼西亚 · 苏门答腊"),
    (["卢旺达", "Rwanda"], "卢旺达"),
]

PROCESS_RULES: List[Tuple[List[str], str]] = [
    (["双重厌氧水洗"], "双重厌氧水洗"),
    (["双重厌氧日晒"], "双重厌氧日晒"),
    (["厌氧日晒", "Anaerobic Natural"], "厌氧日晒 (Anaerobic Natural)"),
    (["厌氧水洗", "Anaerobic Washed"], "厌氧水洗 (Anaerobic Washed)"),
    (["厌氧蜜处理"], "厌氧蜜处理"),
    (["厌氧"], "厌氧发酵 (Anaerobic)"),
    (["雪莉桶", "威士忌桶", "酒桶发酵", "Barrel"], "酒桶发酵 (Barrel Aged)"),
    (["热冲击", "Thermal Shock"], "热冲击处理 (Thermal Shock)"),
    (["红蜜"], "红蜜处理 (Red Honey)"),
    (["黄蜜"], "黄蜜处理 (Yellow Honey)"),
    (["黑蜜"], "黑蜜处理 (Black Honey)"),
    (["蜜处理", "Honey"], "蜜处理 (Honey)"),
    (["湿刨", "Wet Hulled"], "湿刨法 (Wet Hulled)"),
    (["日晒", "Natural"], "日晒 (Natural)"),
    (["水洗", "Washed"], "水洗 (Washed)"),
]

ROAST_RULES: List[Tuple[List[str], str]] = [
    (["极浅烘", "极浅度"], "极浅烘焙"),
    (["中浅烘", "浅中烘", "中浅度", "Medium-Light"], "中浅烘焙"),
    (["中深烘", "深中烘", "中深度", "Medium-Dark"], "中深烘焙"),
    (["浅烘", "浅度烘焙", "浅度", "Light"], "浅度烘焙"),
    (["中烘", "中度烘焙", "中度", "Medium"], "中度烘焙"),
    (["深烘", "深度烘焙", "深度", "Dark"], "深度烘焙"),
]

FLAVOR_LEXICON: List[str] = [
    "草莓果酱", "奶油太妃糖", "水蜜桃酸奶", "白桃乌龙", "威士忌酒香", "香草奶油",
    "热带水果", "百香果", "水蜜桃", "佛手柑", "茉莉白花", "茉莉花", "玫瑰花",
    "太妃糖", "黑巧克力", "巧克力", "黑巧", "柑橘", "柠檬", "橙花", "白桃",
    "黄桃", "西梅", "蓝莓", "草莓", "黑莓", "树莓", "芒果", "菠萝", "荔枝",
    "葡萄", "红酒", "朗姆酒", "威士忌", "雪莉", "茉莉", "玫瑰", "白花",
    "乌龙茶", "红茶", "绿茶", "蜂蜜", "焦糖", "红糖", "奶油", "酸奶",
    "香草", "榛果", "坚果", "杏仁", "可可",
]

VARIETAL_OR_ESTATE_ALIASES: List[str] = [
    "红标瑰夏", "绿标瑰夏", "蓝标瑰夏", "花魁7.0", "花魁", "瑰夏",
    "翡翠庄园", "天堂庄园", "果丁丁", "耶加雪菲", "罕贝拉", "西达摩",
    "雪莉", "曼特宁", "铁皮卡", "波旁", "粉波旁", "希爪", "卡杜拉", "SL28",
]

DEFAULT_SEEDED_ROAST_DATES: Dict[str, str] = {
    "bean-huakui": "2026-11-05",
    "bean-geisha": "2026-11-15",
    "bean-paraiso": "2026-10-16",
}


def normalize_date_str(raw_date: Optional[str]) -> Optional[str]:
    if not raw_date:
        return None
    m = re.search(r"(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})", str(raw_date))
    if not m:
        return None
    try:
        dt = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        return dt.isoformat()
    except ValueError:
        return None


def compute_freshness_metrics(
    roast_date_str: Optional[str],
    reference_date: Optional[date] = None,
) -> Tuple[Optional[int], str]:
    normalized = normalize_date_str(roast_date_str)
    if not normalized:
        return None, "未知烘焙期"
    roast_dt = date.fromisoformat(normalized)
    today = reference_date or datetime.now().date()
    days = max(0, (today - roast_dt).days)
    if days <= 4:
        stage = "养豆期 (Degassing)"
    elif days <= 28:
        stage = "黄金赏味期 (Peak Window)"
    else:
        stage = "风味衰退期 (Aging)"
    return days, stage


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
    roast_date: str = "2026-11-05"
    initial_weight_g: float = 250.0
    remaining_weight_g: float = 200.0
    bag_status: str = "active"        # "active" | "frozen" | "finished"
    brew_count: int = 0
    name: str = ""


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

    @staticmethod
    def _normalize_bean_dict(bean: Dict[str, Any]) -> Dict[str, Any]:
        b = dict(bean)
        aliases = b.get("short_aliases") or []
        if isinstance(aliases, str):
            aliases = [x.strip() for x in aliases.split(",") if x.strip()]
        b["short_aliases"] = aliases

        flavors = b.get("flavor_tags") or []
        if isinstance(flavors, str):
            flavors = [x.strip() for x in flavors.split(",") if x.strip()]
        b["flavor_tags"] = flavors

        full_name = (b.get("full_name") or b.get("name") or "未命名咖啡豆").strip()
        b["full_name"] = full_name
        b["name"] = (b.get("name") or (aliases[0] if aliases else full_name)).strip()

        raw_roast_date = b.get("roast_date") or DEFAULT_SEEDED_ROAST_DATES.get(str(b.get("bean_id", "")))
        normalized_roast_date = normalize_date_str(raw_roast_date) or (
            datetime.now().date() - timedelta(days=10)
        ).isoformat()
        b["roast_date"] = normalized_roast_date

        rem_raw = b.get("remaining_weight_g")
        remaining_g = round(max(0.0, float(rem_raw if rem_raw is not None else 200.0)), 2)
        init_raw = b.get("initial_weight_g")
        initial_g = round(max(0.0, float(init_raw if init_raw is not None else max(250.0, remaining_g))), 2)
        if init_raw is None and initial_g < remaining_g:
            initial_g = remaining_g
        b["initial_weight_g"] = initial_g
        b["remaining_weight_g"] = remaining_g

        b["brew_count"] = max(0, int(b.get("brew_count") or 0))
        status = str(b.get("bag_status") or "").strip().lower()
        if status not in ("active", "frozen", "finished"):
            status = "finished" if remaining_g <= 0.0 else "active"
        elif remaining_g <= 0.0 and status == "active":
            status = "finished"
        b["bag_status"] = status

        days_off_roast, freshness_stage = compute_freshness_metrics(b["roast_date"])
        b["days_off_roast"] = days_off_roast
        b["freshness_stage"] = freshness_stage
        return b

    def _ensure_seeded(self) -> None:
        os.makedirs(self.data_dir, exist_ok=True)
        if not os.path.exists(self.file_path):
            default_beans = [
                self._normalize_bean_dict(
                    asdict(
                        BeanEntry(
                            bean_id="bean-huakui",
                            name="罕贝拉 花魁 7.0",
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
                            roast_date="2026-11-05",
                            initial_weight_g=250.0,
                            remaining_weight_g=185.0,
                            bag_status="active",
                            brew_count=3,
                        )
                    )
                ),
                self._normalize_bean_dict(
                    asdict(
                        BeanEntry(
                            bean_id="bean-geisha",
                            name="翡翠庄园 绿标瑰夏",
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
                            roast_date="2026-11-15",
                            initial_weight_g=200.0,
                            remaining_weight_g=140.0,
                            bag_status="active",
                            brew_count=3,
                        )
                    )
                ),
                self._normalize_bean_dict(
                    asdict(
                        BeanEntry(
                            bean_id="bean-paraiso",
                            name="天堂庄园 双重厌氧",
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
                            roast_date="2026-10-16",
                            initial_weight_g=250.0,
                            remaining_weight_g=210.0,
                            bag_status="active",
                            brew_count=2,
                        )
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
            data = json.load(f)
        data["beans"] = [self._normalize_bean_dict(b) for b in data.get("beans", [])]
        return data

    def save_all(self, data: Dict[str, Any]) -> None:
        if "beans" in data and isinstance(data["beans"], list):
            data["beans"] = [self._normalize_bean_dict(b) for b in data["beans"]]
        with open(self.file_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    @staticmethod
    def _find_bean_index(beans: List[Dict[str, Any]], query: str) -> Optional[int]:
        q = (query or "").strip().lower()
        if not q:
            return None
        # 1. Exact ID / full_name / name / alias match
        for idx, bean in enumerate(beans):
            if str(bean.get("bean_id", "")).lower() == q:
                return idx
            if str(bean.get("full_name", "")).lower() == q:
                return idx
            if str(bean.get("name", "")).lower() == q:
                return idx
            if any(str(a).lower() == q for a in bean.get("short_aliases", []) if a):
                return idx
        # 2. Substring alias or name match
        for idx, bean in enumerate(beans):
            for alias in bean.get("short_aliases", []):
                if alias and alias.lower() in q:
                    return idx
            full_name = str(bean.get("full_name", "")).lower()
            if full_name and (full_name in q or q in full_name):
                return idx
        return None

    def match_bean_by_text(self, text: str) -> Optional[Dict[str, Any]]:
        """
        Matches spoken shorthand (e.g. '今天用花魁' or '冲一杯瑰夏') against the user's Bean Library
        and returns the full bean profile so the user doesn't have to recite origin/process/roast every time.
        """
        data = self.load_all()
        beans = data.get("beans", [])
        idx = self._find_bean_index(beans, text)
        return beans[idx] if idx is not None else None

    def add_or_update_bean(self, bean_dict: Dict[str, Any]) -> Dict[str, Any]:
        data = self.load_all()
        beans = data.get("beans", [])
        incoming = dict(bean_dict)
        bean_id = incoming.get("bean_id") or f"bean-{datetime.now().strftime('%H%M%S')}"
        incoming["bean_id"] = bean_id

        replaced_entry: Optional[Dict[str, Any]] = None
        for i, b in enumerate(beans):
            if b.get("bean_id") == bean_id:
                merged = self._normalize_bean_dict({**b, **incoming})
                beans[i] = merged
                replaced_entry = merged
                break
        if replaced_entry is None:
            replaced_entry = self._normalize_bean_dict(incoming)
            beans.insert(0, replaced_entry)
        data["beans"] = beans
        self.save_all(data)
        return replaced_entry

    def deduct_bean_dose(self, bean_id_or_name: str, dose_g: float) -> Optional[Dict[str, Any]]:
        """
        Automatically deducts `dose_g` from `remaining_weight_g` (clamped at 0.0),
        increments `brew_count`, updates `bag_status` if finished, and computes
        `days_off_roast` and `freshness_stage`.
        """
        if not bean_id_or_name or dose_g is None:
            return None
        try:
            dose_val = max(0.0, float(dose_g))
        except (TypeError, ValueError):
            return None

        data = self.load_all()
        beans = data.get("beans", [])
        idx = self._find_bean_index(beans, bean_id_or_name)
        if idx is None:
            return None

        bean = dict(beans[idx])
        current_remaining = float(bean.get("remaining_weight_g", bean.get("initial_weight_g", 200.0)))
        new_remaining = round(max(0.0, current_remaining - dose_val), 2)
        bean["remaining_weight_g"] = new_remaining
        bean["brew_count"] = int(bean.get("brew_count") or 0) + 1
        if new_remaining <= 0.0 and bean.get("bag_status") != "frozen":
            bean["bag_status"] = "finished"

        normalized = self._normalize_bean_dict(bean)
        beans[idx] = normalized
        data["beans"] = beans
        self.save_all(data)
        return normalized

    def parse_bean_label_text(self, ocr_or_note_text: str) -> Dict[str, Any]:
        """
        Extracts structured bean card fields (`name`, `full_name`, `origin`, `process`,
        `roast_level`, `flavor_tags`, `initial_weight_g`, `roast_date`) from natural language
        or OCR text on a coffee bag (Brewlog / Filtru AI bag scanner style) and saves/updates
        it in the bean library.
        """
        raw = (ocr_or_note_text or "").strip()
        if not raw:
            default_card = {
                "bean_id": f"bean-scan-{datetime.now().strftime('%H%M%S')}",
                "name": "未命名豆袋",
                "full_name": "未命名豆袋",
                "short_aliases": ["未命名豆袋"],
                "origin": "未知产区",
                "process": "水洗 (Washed)",
                "roast_level": "中浅烘焙",
                "flavor_tags": ["柑橘", "坚果"],
                "initial_weight_g": 250.0,
                "remaining_weight_g": 250.0,
                "roast_date": datetime.now().date().isoformat(),
                "bag_status": "active",
                "brew_count": 0,
                "recommended_grind": "刻度 14.0 格",
                "recommended_dose_g": 18.0,
                "recommended_ratio": "1:2.0",
                "golden_recipe_note": "AI 豆袋标签自动建档",
            }
            return self.add_or_update_bean(default_card)

        # 1. Roast date
        roast_date = normalize_date_str(raw) or datetime.now().date().isoformat()

        # 2. Bag weight (initial_weight_g & optional remaining_weight_g)
        weight_matches = [
            float(m.group(1))
            for m in re.finditer(r"(\d+(?:\.\d+)?)\s*(?:g|G|克|grams?)(?![a-zA-Z])", raw)
        ]
        bag_weights = [w for w in weight_matches if w >= 30.0]
        initial_weight_g = bag_weights[0] if bag_weights else (weight_matches[0] if weight_matches else 250.0)
        rem_match = re.search(r"(?:剩余|余量)\s*(\d+(?:\.\d+)?)\s*(?:g|G|克)", raw)
        remaining_weight_g = float(rem_match.group(1)) if rem_match else initial_weight_g

        # 3. Origin
        explicit_origin = re.search(r"产地\s*[:：]\s*([^\s,，;；\n]+)", raw)
        origin = explicit_origin.group(1).strip() if explicit_origin else ""
        if not origin:
            for keywords, label in ORIGIN_RULES:
                if any(kw.lower() in raw.lower() for kw in keywords):
                    origin = label
                    break
        if not origin:
            origin = "精品单品产区"

        # 4. Process
        process = ""
        for keywords, label in PROCESS_RULES:
            if any(kw.lower() in raw.lower() for kw in keywords):
                process = label
                break
        if not process:
            process = "水洗 (Washed)"

        # 5. Roast level
        roast_level = ""
        for keywords, label in ROAST_RULES:
            if any(kw.lower() in raw.lower() for kw in keywords):
                roast_level = label
                break
        if not roast_level:
            roast_level = "中浅烘焙"

        # 6. Flavor tags (handles both contiguous Chinese notes like "柑橘茉莉花水蜜桃" and delimited lists)
        found_flavors: List[Tuple[int, str]] = []
        masked = raw
        for note in sorted(FLAVOR_LEXICON, key=len, reverse=True):
            pos = masked.find(note)
            if pos != -1:
                found_flavors.append((pos, note))
                masked = masked.replace(note, " " * len(note), 1)
        found_flavors.sort(key=lambda item: item[0])
        flavor_tags = [note for _, note in found_flavors]

        explicit_flavor = re.search(r"风味(?:描述|标签)?\s*[:：]\s*([^\n;；]+)", raw)
        if explicit_flavor:
            for tok in re.split(r"[,，、/·\s]+", explicit_flavor.group(1).strip()):
                tok = tok.strip()
                if tok and not re.search(r"烘焙|日期|\d+g|\d+克", tok, re.I) and tok not in flavor_tags:
                    flavor_tags.append(tok)
        if not flavor_tags:
            flavor_tags = ["柑橘", "花香", "焦糖甜感"]

        # 7. Extract clean bean name & full_name
        cleaned = raw
        cleaned = re.sub(r"烘焙(?:日期|时间)?\s*[:：]?\s*20\d{2}\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}日?", " ", cleaned)
        cleaned = re.sub(r"20\d{2}\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}日?", " ", cleaned)
        cleaned = re.sub(r"(?:净含量|豆重|克重|剩余|余量)?\s*\d+(?:\.\d+)?\s*(?:g|G|克|grams?)(?![a-zA-Z])", " ", cleaned)
        cleaned = re.sub(r"(?:风味(?:描述|标签)?|产地|处理法|烘焙度?)\s*[:：]\s*[^\s,，;；\n]+", " ", cleaned)
        for note in sorted(FLAVOR_LEXICON, key=len, reverse=True):
            cleaned = cleaned.replace(note, " ")
        for kw_group, _ in ROAST_RULES:
            for kw in kw_group:
                cleaned = re.sub(re.escape(kw), " ", cleaned, flags=re.I)
        process_short = process.split(" ")[0]
        for kw_group, _ in PROCESS_RULES:
            for kw in kw_group:
                cleaned = re.sub(re.escape(kw), " ", cleaned, flags=re.I)

        tokens = [t.strip("·-—_/,，、:：()（）") for t in re.split(r"[\s,，;；|]+", cleaned) if t.strip("·-—_/,，、:：()（）")]
        tokens = [t for t in tokens if t not in ("烘焙日期", "烘焙", "净含量", "风味", "咖啡豆")]

        base_name = " ".join(tokens[:3]).strip() if tokens else ""
        if not base_name:
            base_name = f"{origin.split('·')[0].strip()} {process_short}".strip()

        name = base_name
        full_name = base_name if process_short in base_name else f"{base_name} {process_short}".strip()

        # 8. Build spoken short_aliases
        aliases: List[str] = []
        for candidate in VARIETAL_OR_ESTATE_ALIASES:
            if candidate.lower() in raw.lower() and candidate not in aliases:
                aliases.append(candidate)
        if name not in aliases:
            aliases.insert(0, name)
        if tokens and tokens[-1] not in aliases and len(tokens[-1]) >= 2:
            aliases.append(tokens[-1])

        # Recommended grind & ratio heuristics based on roast level
        if "浅" in roast_level and "中" not in roast_level:
            rec_grind, rec_ratio = "刻度 13.5 格", "1:2.2"
        elif "深" in roast_level:
            rec_grind, rec_ratio = "刻度 15.0 格", "1:1.8"
        else:
            rec_grind, rec_ratio = "刻度 14.2 格", "1:2.0"

        slug_hash = hashlib.sha1(full_name.lower().encode("utf-8")).hexdigest()[:8]
        bean_id = f"bean-{slug_hash}"

        # Reuse existing bean_id if exact full_name already exists
        existing_data = self.load_all()
        for existing in existing_data.get("beans", []):
            if str(existing.get("full_name", "")).strip().lower() == full_name.lower():
                bean_id = existing["bean_id"]
                break

        bean_card = {
            "bean_id": bean_id,
            "name": name,
            "full_name": full_name,
            "short_aliases": aliases[:6],
            "origin": origin,
            "process": process,
            "roast_level": roast_level,
            "flavor_tags": flavor_tags[:8],
            "recommended_grind": rec_grind,
            "recommended_dose_g": 18.0,
            "recommended_ratio": rec_ratio,
            "golden_recipe_note": f"AI 豆袋扫描入库 · 建议 {rec_grind} / 18g 粉 ({rec_ratio})",
            "roast_date": roast_date,
            "initial_weight_g": round(initial_weight_g, 2),
            "remaining_weight_g": round(remaining_weight_g, 2),
            "bag_status": "finished" if remaining_weight_g <= 0 else "active",
            "brew_count": 0,
        }
        return self.add_or_update_bean(bean_card)

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
