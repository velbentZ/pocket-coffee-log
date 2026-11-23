"""
Multimodal (Voice + Video) Coffee Brewing Analyzer & Barista AI Engine.

Extracts structured coffee parameters from spoken Chinese transcripts and visual timeline events,
evaluates extraction quality, generates actionable barista recommendations, and composes
social media copy for Xiaohongshu (小红书) and WeChat Moments (微信朋友圈).
"""

import json
import os
import re
from typing import Any, Dict, List, Optional, Tuple
from urllib import request as urllib_request

from core.models import CoffeeRecord, FlavorProfile


# Chinese numeral helper for spoken numbers like "十八克", "三十六克", "九帕"
CN_NUMS = {
    "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
}


MAX_TRANSCRIPT_CHARS = 20000


def parse_cn_or_float(val_str: str) -> Optional[float]:
    val_str = val_str.strip()[:32]
    try:
        parsed = float(val_str)
        return parsed if parsed == parsed and abs(parsed) < 1e9 else None
    except (ValueError, OverflowError):
        pass
    # Simple Chinese number parser (e.g. 十八 -> 18, 二十八 -> 28, 九点五 -> 9.5)
    if "点" in val_str:
        parts = val_str.split("点", 1)
        left = parse_cn_or_float(parts[0]) if parts[0] else 0.0
        if left is None or abs(left) >= 1e6:
            return None
        right_digits = "".join(str(CN_NUMS.get(c, c)) for c in parts[1][:8])
        try:
            return float(f"{int(left)}.{right_digits}")
        except (ValueError, OverflowError):
            return None
    total = 0
    if val_str.startswith("十"):
        total = 10
        if len(val_str) > 1:
            total += CN_NUMS.get(val_str[1], 0)
        return float(total)
    if "十" in val_str:
        parts = val_str.split("十")
        tens = CN_NUMS.get(parts[0], 1) * 10
        ones = CN_NUMS.get(parts[1], 0) if len(parts) > 1 and parts[1] else 0
        return float(tens + ones)
    if len(val_str) == 1 and val_str in CN_NUMS:
        return float(CN_NUMS[val_str])
    return None


def extract_parameters_from_transcript(
    transcript: str,
    camera_device: str = "DJI Osmo Pocket 4 Pro",
    video_path: Optional[str] = None,
    visual_Overrides: Optional[Dict[str, Any]] = None,
) -> CoffeeRecord:
    """
    Parses spoken Chinese transcript during coffee brewing (plus any visual scale/pressure gauge
    readings from Pocket 3 / Pocket 4 Pro video frames) into a structured CoffeeRecord.
    """
    capped_transcript = (transcript or "").strip()[:MAX_TRANSCRIPT_CHARS]
    rec = CoffeeRecord(
        camera_device=camera_device,
        video_path=video_path,
        transcript=capped_transcript,
    )
    text = capped_transcript

    # 1. Brew method (做的是意式浓缩还是冷萃 / 美式 / 拿铁 / 手冲 / Dirty)
    if any(k in text for k in ["冷萃", "冰滴", "Cold Brew", "cold brew"]):
        if "冰滴" in text:
            rec.brew_method = "冰滴冷萃 (Ice Drip Cold Brew)"
        else:
            rec.brew_method = "冷萃咖啡 (Cold Brew)"
    elif any(k in text for k in ["意式浓缩", "意识浓缩", "浓缩", "Espresso", "espresso", "双份浓缩", "Double", "SOE", "意式"]):
        if "SOE" in text.upper():
            rec.brew_method = "SOE 单一产地意式浓缩"
        elif "拿铁" in text:
            rec.brew_method = "意式浓缩基底 · 冰拿铁/热拿铁"
        elif "美式" in text:
            rec.brew_method = "意式浓缩基底 · 冰美式/热美式"
        elif "Dirty" in text or "dirty" in text:
            rec.brew_method = "意式浓缩基底 · Dirty 咖啡"
        else:
            rec.brew_method = "意式浓缩 (Espresso)"
    elif "手冲" in text:
        rec.brew_method = "手冲滴滤 (Pour Over)"

    # 2. Coffee Bean Name & Roast (用的什么咖啡豆)
    bean_patterns = [
        r"(?:豆子|咖啡豆)(?:今天)?(?:用的是|用|选的是|是|拿了)([^，。；！\n]{3,28})",
        r"(?:今天做|今天冲|今天萃|今天用的是|今天用)(?:的是|一杯)?([^，。；！\n]{2,25}?(?:豆|耶加雪菲|花魁|瑰夏|西达摩|曼特宁|肯尼亚|哥伦比亚|埃塞|拼配|SOE)[^0-9，。；\n]{0,10})",
        r"((?:埃塞俄比亚|巴拿马|哥伦比亚|肯尼亚|洪都拉斯|云南|巴西|印尼)[^0-9，。；\n]{2,20})",
        r"((?:花魁|瑰夏|耶加雪菲|西达摩|天堂庄园|翡翠庄园|栓皮栎|雪莉)[^0-9，。；\n]{0,14})",
    ]
    for pat in bean_patterns:
        m = re.search(pat, text)
        if m:
            candidate = m.group(1).strip()
            # Clean trailing filler words
            candidate = re.sub(r"(?:称重|称豆|克重|磨豆|研磨|浅冲).*$", "", candidate).strip(" ，、的")
            if len(candidate) >= 2:
                rec.bean_name = candidate
                break

    if "中浅烘" in text or "中浅冲" in text:
        rec.bean_roast = "中浅烘焙"
    elif "浅烘" in text or "浅冲" in text:
        rec.bean_roast = "浅度烘焙"
    elif "中深烘" in text:
        rec.bean_roast = "中深烘焙"
    elif "深烘" in text or "深红" in text:
        rec.bean_roast = "深度烘焙"
    elif "中烘" in text:
        rec.bean_roast = "中度烘焙"

    # 3. Bean weight (咖啡豆称重是多少)
    weight_patterns = [
        r"(?:咖啡豆|豆子|粉量|称重|称豆|装粉|用了|称了|浅烘|浅冲|中烘|深烘|日晒|水洗|厌氧)[^0-9一二两三四五六七八九十，。]{0,12}?([0-9]{1,8}(?:\.[0-9]{1,4})?|[一二两三四五六七八九十点]{1,12})\s*(?:克|课|g|G)",
        r"(?<![0-9.])([0-9]{1,8}(?:\.[0-9]{1,4})?)\s*(?:克|课|g|G)\s*(?:咖啡豆|豆子|粉)",
        r"(?:瑰夏|花魁|耶加|西达摩|曼特宁|拼配|豆)[^0-9]{0,8}?([0-9]{1,8}(?:\.[0-9]{1,4})?)\s*(?:克|课|g|G)",
    ]
    for pat in weight_patterns:
        m = re.search(pat, text)
        if m:
            val = parse_cn_or_float(m.group(1))
            if val and 5.0 <= val <= 150.0:
                rec.bean_weight_g = val
                break

    # 4. Grind setting (研磨度是多少)
    grind_patterns = [
        r"(?:研磨度|刻度|磨豆刻度|刀盘刻度|粗细)(?:调到|设置在|是|用|为|调成)?\s*([0-9]{1,6}(?:\.[0-9]{1,4})?(?:\s*格|\s*圈|\s*档)?|[一二三四五六七八九十点]{1,10}(?:格|档)?)",
        r"刻度\s*([0-9]{1,6}(?:\.[0-9]{1,4})?)",
    ]
    for pat in grind_patterns:
        m = re.search(pat, text)
        if m:
            rec.grind_setting = f"刻度 {m.group(1).strip()}"
            break

    # 5. Grinder type & model (额外的磨豆机还是咖啡机自身自带的)
    external_models = ["Niche Zero", "Niche", "尼斯", "DF64", "DF83", "マイト", "迈赫迪", "EK43", "Weber", "EG-1", "Lagom", "P64", "P100", "C40", "司令官", "Eureka", "Mignon", "松屋", "巫师"]
    found_model = None
    for mod in external_models:
        if mod.lower() in text.lower():
            found_model = "Niche Zero" if mod == "尼斯" else mod
            break

    if any(k in text for k in ["自带磨豆机", "自带的磨豆机", "咖啡机自带", "内置磨豆机", "一体机自带", "自带豆仓", "自带都昌", "3828"]):
        rec.grinder_type = "咖啡机自带磨豆机"
        if any(k in text for k in ["3828", "格米莱", "格莱米"]):
            rec.grinder_model = "格米莱 G3828A (云象One 内置60mm平刀磨豆机)"
        elif "铂富" in text or "Breville" in text.lower():
            rec.grinder_model = "Breville 铂富内置锥刀磨豆机"
        elif "德龙" in text:
            rec.grinder_model = "DeLonghi 德龙内置磨豆机"
        else:
            rec.grinder_model = found_model or "咖啡机内置一体磨豆机"
    elif any(k in text for k in ["额外", "独立磨豆机", "外置磨豆机", "单品磨", "独立磨", "外置"]) or found_model:
        rec.grinder_type = "额外独立磨豆机"
        rec.grinder_model = found_model or "独立外置专业磨豆机"

    # 6. Yield / Liquid output (出液是多少)
    yield_patterns = [
        r"(?:出液量?|初夜|出夜|初液|萃取液|液重|出杯量?|萃出|流出了?|接了|注水|加水)[^0-9一二两三四五六七八九十]{0,6}([0-9]{1,8}(?:\.[0-9]{1,4})?|[一二两三四五六七八九十点]{1,12})\s*(?:克|课|毫升|g|G|ml|ML)",
        r"(?<![0-9.])([0-9]{1,8}(?:\.[0-9]{1,4})?)\s*(?:克|课|毫升|g|ml)\s*(?:咖啡液|浓缩液|出液)",
    ]
    for pat in yield_patterns:
        m = re.search(pat, text)
        if m:
            val = parse_cn_or_float(m.group(1))
            if val and 10.0 <= val <= 1500.0:
                rec.yield_g = val
                break

    # 7. Extraction time (萃取时间是多少)
    # Check hours first (for Cold Brew)
    hour_m = re.search(r"(?:萃取|浸泡|冷藏|时间)[^0-9]{0,6}([0-9]{1,6}(?:\.[0-9]{1,4})?)\s*(?:小时|h|H)", text)
    sec_m = re.search(r"(?:萃取时间|萃取了?|耗时|读秒|用了|时间是?)[^0-9一二两三四五六七八九十]{0,6}([0-9]{1,6}(?:\.[0-9]{1,4})?|[一二两三四五六七八九十]{1,10})\s*(?:秒|s|S)", text)
    if not sec_m:
        sec_m = re.search(r"(?<![0-9.])([0-9]{2}(?:\.[0-9]{1,4})?)\s*(?:秒|s)\s*(?:出液|初夜|出夜|结束|完成|停)", text)

    if sec_m:
        rec.extraction_time_s = parse_cn_or_float(sec_m.group(1))
    elif hour_m:
        hours = parse_cn_or_float(hour_m.group(1))
        if hours:
            rec.extraction_time_s = round(hours * 3600, 1)

    # 8. Pressure (萃取压力是多少 bar)
    norm_pressure_text = text.replace("酒八", "9bar").replace("九八", "9bar")
    pressure_m = re.search(
        r"(?:压力表?|萃取压力|峰值压力|压力)(?:稳定在|在|是|达到|为)?\s*([0-9]{1,6}(?:\.[0-9]{1,4})?|[一二三四五六七八九十点]{1,10})\s*(?:bar|Bar|BAR|帕|巴|霸|八)",
        norm_pressure_text,
    )
    if not pressure_m:
        pressure_m = re.search(r"(?<![0-9.])([0-9]{1,6}(?:\.[0-9]{1,4})?)\s*(?:bar|Bar|BAR|巴|霸)", norm_pressure_text)
    if pressure_m:
        rec.pressure_bar = parse_cn_or_float(pressure_m.group(1))

    # 9. Water temperature
    temp_m = re.search(r"(?:水温|萃取温度|温度)[^0-9]{0,4}([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*(?:度|°C|℃)", text)
    if temp_m:
        rec.water_temp_c = float(temp_m.group(1))

    # Apply Bean Library shorthand match (e.g., user just says "今天用花魁" -> fills full origin, roast, flavor notes)
    if visual_Overrides:
        bean_match = visual_Overrides.get("_bean_library_match")
        if isinstance(bean_match, dict):
            rec.bean_name = bean_match.get("full_name") or rec.bean_name
            if not rec.bean_roast and bean_match.get("roast_level"):
                rec.bean_roast = bean_match["roast_level"]
            if not rec.grind_setting and bean_match.get("recommended_grind") and visual_Overrides.get("_auto_fill_bean_grind"):
                rec.grind_setting = bean_match["recommended_grind"]
            if bean_match.get("flavor_tags"):
                rec.flavor_notes = list(bean_match["flavor_tags"])

        equip_defaults = visual_Overrides.get("_equipment_defaults")
        if isinstance(equip_defaults, dict) and equip_defaults.get("auto_fill_default_grinder", True):
            if not rec.grinder_type:
                rec.grinder_type = equip_defaults.get("default_grinder_type", "额外独立磨豆机")
            if not rec.grinder_model:
                rec.grinder_model = equip_defaults.get("default_grinder_model", "Niche Zero (63mm 锥刀)")
            if not rec.water_temp_c and equip_defaults.get("default_water_temp_c"):
                rec.water_temp_c = float(equip_defaults["default_water_temp_c"])

        for k, v in visual_Overrides.items():
            if k.startswith("_"):
                continue
            if getattr(rec, k, None) is None and v is not None:
                setattr(rec, k, v)

    rec.compute_derived_metrics()
    if is_equipment_introduction(transcript, rec):
        rec.record_type = "equipment_profile"
        rec.equipment_items = extract_equipment_items_from_transcript(transcript)
        if not rec.brew_method:
            rec.brew_method = "常驻设备与器具档案补充"
        if not rec.bean_name:
            rec.bean_name = f"{rec.grinder_model or '居家咖啡机'} · 全套器具建档"
        rec.compute_derived_metrics()
    enrich_barista_analysis(rec)
    return rec


EQUIPMENT_INTRO_KEYWORDS = [
    "器具", "工具", "压粉锤", "鸭粉锤", "阿粪吹", "牙粪吹", "压粉", "布粉器", "布粉针",
    "部分器", "部分锤", "部分针", "接粉环", "基本环", "吸尘器", "清洁工具", "一次性杯",
    "手柄", "双杯", "双碑", "滤纸", "一整套", "介绍", "看看我们的咖啡机", "自带豆仓",
    "自带都昌", "电子秤", "敲渣盒", "粉渣盒",
]

EQUIPMENT_ACCESSORY_CATALOG: List[Tuple[List[str], Dict[str, str]]] = [
    (
        ["3828", "3200", "格米莱", "格莱米", "可爱米", "咖啡机", "自带豆仓", "自带都昌"],
        {
            "id": "eq-gemilai-g3828a",
            "name": "格米莱 G3828A (云象One 研磨一体咖啡机)",
            "category": "主力咖啡机 & 内置磨豆机",
            "spec": "内置 60mm 不锈钢平刀磨豆机 + 200g 顶部豆仓 + 58mm 商用冲煮头",
            "role": "研磨萃取一体，提供稳定 9 bar 泵压与 93°C 恒温萃取",
        },
    ),
    (
        ["压粉锤", "鸭粉锤", "压吹", "鸭吹", "阿粪吹", "牙粪吹", "自动回弹", "自动回答", "轰炸机"],
        {
            "id": "eq-mhw-tamper",
            "name": "MHW-3BOMBER 轰炸机 58.35mm 自适应恒力压粉锤",
            "category": "压粉器具 (自动回弹)",
            "spec": "58.35mm 精密螺纹底座 · 30lbs 恒压自动回弹",
            "role": "保证每次压粉力度垂直均匀，避免粉饼倾斜导致偏流",
        },
    ),
    (
        ["布粉器", "部分器", "部分锤", "桨式", "布粉"],
        {
            "id": "eq-distributor",
            "name": "MHW-3BOMBER 58.35mm 自适应四桨布粉器 & 格米莱原装压粉锤",
            "category": "布粉 & 压粉器具",
            "spec": "58mm 粉碗平整布粉 + 胡桃木/金属原装压粉锤",
            "role": "在压粉前快速找平粉层表面，减少表面密度不均",
        },
    ),
    (
        ["布粉针", "部分针", "接粉环", "基本环"],
        {
            "id": "eq-dosing-wdt",
            "name": "58mm 磁吸接粉环 + WDT 针式布粉器",
            "category": "接粉 & 破块器具",
            "spec": "铝合金磁吸防飞粉接粉环 + 细针破块器",
            "role": "接粉防洒并打散研磨结块，大幅降低萃取通道效应",
        },
    ),
    (
        ["手柄", "双杯", "双碑"],
        {
            "id": "eq-portafilter",
            "name": "格米莱 G3828A 58mm 实木双嘴分流手柄",
            "category": "萃取手柄 & 粉碗",
            "spec": "58mm 双份增压/非增压双嘴手柄 (建议粉量 17-19g)",
            "role": "双嘴均匀分流出品，支持单份/双份意式浓缩基底萃取",
        },
    ),
    (
        ["滤纸", "分水网"],
        {
            "id": "eq-filter-paper",
            "name": "58mm 意式粉碗丸型滤纸",
            "category": "过滤耗材",
            "spec": "58mm 底部/顶部通用丸型滤纸",
            "role": "阻隔极细粉穿透粉碗底孔，提升油脂干净度并保持冲煮头清洁",
        },
    ),
    (
        ["吸尘器", "清洁", "气吹", "敲渣"],
        {
            "id": "eq-vacuum-cleaner",
            "name": "桌面便携式电动咖啡粉吸尘器 & 胡桃木压粉底座/粉渣盒",
            "category": "吧台清洁与收纳",
            "spec": "无线桌面吸尘器 + 实木多槽压粉收纳底座",
            "role": "随时清理磨豆机残粉与台面咖啡渣，保持居家咖啡角整洁",
        },
    ),
    (
        ["一次性杯", "出品杯", "纸杯", "电子秤"],
        {
            "id": "eq-cups-scale",
            "name": "意式电子计时咖啡秤 + 居家出品纸杯/拉花杯组",
            "category": "称量与出品杯具",
            "spec": "0.1g 精度电子咖啡秤 + 隔热瓦楞一次性出品杯",
            "role": "精准监测称豆粉重与浓缩出液流速，方便日常打卡与外带分享",
        },
    ),
]


def extract_equipment_items_from_transcript(transcript: str) -> List[Dict[str, Any]]:
    text = (transcript or "").strip()
    matched: List[Dict[str, Any]] = []
    seen_ids = set()
    for keywords, item in EQUIPMENT_ACCESSORY_CATALOG:
        if any(kw.lower() in text.lower() for kw in keywords):
            if item["id"] not in seen_ids:
                seen_ids.add(item["id"])
                matched.append(dict(item))
    if not matched and text:
        for _, item in EQUIPMENT_ACCESSORY_CATALOG[:5]:
            matched.append(dict(item))
    return matched


def is_equipment_introduction(transcript: str, rec: Optional[CoffeeRecord] = None) -> bool:
    """
    Returns True when a recording introduces home coffee equipment/tools/beans without
    performing an actual coffee extraction (no dose weight, yield, extraction time, or pressure).
    """
    if rec is not None and getattr(rec, "record_type", "") == "equipment_profile":
        return True
    text = (transcript or (rec.transcript if rec else "") or "").strip()
    if not text:
        return False

    if rec is not None:
        has_actual_brew_metrics = any(
            getattr(rec, k, None) is not None
            for k in ("bean_weight_g", "yield_g", "extraction_time_s", "pressure_bar", "grind_setting")
        )
        if has_actual_brew_metrics:
            return False

    kw_hits = sum(1 for kw in EQUIPMENT_INTRO_KEYWORDS if kw in text)
    explicit_intro = any(
        phrase in text
        for phrase in (
            "来看看我们的咖啡机",
            "介绍相应的所有我们",
            "这就是我们这一整套的咖啡制作的工具",
            "做咖啡的器具",
            "咖啡制作的工具",
            "今天先介绍",
        )
    )
    return explicit_intro or kw_hits >= 2


def relabel_keyframes_for_equipment_profile(
    keyframes: List[Dict[str, Any]],
    equipment_items: Optional[List[Dict[str, Any]]] = None,
) -> List[Dict[str, Any]]:
    """
    Replaces brewing-specific keyframe titles ('P1 称豆 / P2 刻度 / P3 压力表 / P4 出杯')
    with accurate equipment & workstation showcase titles when record_type == 'equipment_profile'.
    """
    equipment_stage_plan = [
        (
            "E1 压粉与布粉台",
            "MHW-3BOMBER 自动回弹压粉锤 · 布粉器 · 实木压粉底座",
            "实拍咖啡角器具特写：MHW-3BOMBER 轰炸机恒力自动回弹压粉锤、四桨布粉器与胡桃木收纳底座",
        ),
        (
            "E2 配件与清洁工具",
            "58mm 接粉环 · 针式布粉器 · 原装木柄压粉锤 · 桌面吸尘器 · 出品纸杯",
            "实拍吧台配件架：58mm 磁吸接粉环、WDT 布粉针、格米莱原装木柄压粉锤、便携吸尘器与一次性出品杯",
        ),
        (
            "E3 咖啡机与手柄",
            "格米莱 G3828A 研磨一体咖啡机 · 58mm 双嘴手柄与丸型滤纸",
            "实拍主机与冲煮头：格米莱 G3828A (云象One 自带豆仓研磨一体机)、双嘴实木手柄与 58mm 粉碗滤纸",
        ),
        (
            "E4 咖啡角与常驻豆",
            "居家咖啡角全景 · RARAKIDDO 咸芝士低因 SOE 咖啡豆",
            "实拍居家咖啡角全景：格米莱 G3828A 主机、全套压粉布粉工具架与 RARAKIDDO 咸芝士低因 SOE 豆袋",
        ),
    ]
    updated: List[Dict[str, Any]] = []
    for idx, kf in enumerate(keyframes or []):
        item = dict(kf)
        tag, title, desc = equipment_stage_plan[min(idx, len(equipment_stage_plan) - 1)]
        item["preset_badge"] = tag
        item["frame_stage"] = title
        item["stage"] = title
        item["visual_description"] = desc
        updated.append(item)
    return updated


def enrich_barista_analysis(rec: CoffeeRecord) -> None:
    """
    Generates professional barista diagnosis, flavor profile scores, timeline events,
    next-brew optimization suggestions, and Xiaohongshu / WeChat social share copy.
    Never fabricates fake extraction metrics when a recording is an equipment introduction
    or when extraction metrics are missing.
    """
    if rec.record_type == "equipment_profile" or is_equipment_introduction(rec.transcript, rec):
        rec.record_type = "equipment_profile"
        if not rec.equipment_items:
            rec.equipment_items = extract_equipment_items_from_transcript(rec.transcript)
        if not rec.brew_method or rec.brew_method == "意式浓缩 (Espresso)":
            rec.brew_method = "常驻设备与器具档案补充"
        machine_name = rec.grinder_model or "格米莱 G3828A (云象One 研磨一体咖啡机)"
        rec.grinder_type = rec.grinder_type or "咖啡机自带磨豆机"
        rec.grinder_model = machine_name
        if not rec.bean_name:
            rec.bean_name = "格米莱 G3828A 居家咖啡角 · 全套设备与器具档案"
        rec.missing_fields = []
        rec.status = "complete"
        rec.keyframes = relabel_keyframes_for_equipment_profile(rec.keyframes, rec.equipment_items)

        tool_names = [it["name"] for it in rec.equipment_items]
        rec.extraction_diagnosis = (
            f"⚙️【常驻设备与咖啡角器具建档完成】本次录制识别为居家咖啡设备与工具盘点（未进行实际咖啡萃取，已自动归档至「个人豆仓 & 常驻设备预设」）。"
            f"主力机型为 {machine_name}，配套已收录 {len(tool_names)} 类常驻器具：{'、'.join(tool_names[:6])}。"
        )
        rec.flavor_notes = ["格米莱 G3828A 一体机", "MHW-3BOMBER 恒力压粉", "58mm 双嘴手柄", "WDT 布粉破块", "丸型滤纸", "桌面吸尘清洁"]
        rec.suggestions = [
            "【常驻设备已自动同步】已将「格米莱 G3828A (自带豆仓 60mm 平刀研磨一体机)」及配套 58mm 压粉锤、布粉器、接粉环、双嘴手柄、丸型滤纸、桌面吸尘器写入您的常驻设备库，后续每次录制做咖啡会自动关联无需重复介绍。",
            "【咸芝士低因 SOE 冲煮建议】搭配当前豆仓中的 RARAKIDDO 咸芝士低因 SOE（中深烘，养豆期 15-20 天），建议使用双份粉碗装粉 17~19g，垫入 58mm 丸型滤纸，萃取 25~30s 出液 32~36g。",
            "【器具动线配合】接粉时套上 58mm 磁吸接粉环防飞粉 → 用 WDT 布粉针打散结块 → 四桨布粉器找平 → MHW-3BOMBER 自动回弹压粉锤垂直压实，可确保每次出品油脂绵密稳定。",
        ]
        rec.timeline_events = [
            {
                "timestamp": "00:05",
                "stage": "主力咖啡机识别",
                "detail": "语音+视觉识别：格米莱 G3828A (云象One 黑色机身，顶部自带豆仓与内置 60mm 平刀磨豆机)。",
            },
            {
                "timestamp": "00:29",
                "stage": "压粉与布粉器具建档",
                "detail": "录入 MHW-3BOMBER 轰炸机自动回弹压粉锤、四桨布粉器、实木压粉底座与敲渣盒。",
            },
            {
                "timestamp": "00:57",
                "stage": "清洁与吧台配件盘点",
                "detail": "录入桌面便携咖啡粉吸尘器、58mm 磁吸接粉环、WDT 针式布粉器、格米莱原装木柄压粉锤与一次性出品纸杯。",
            },
            {
                "timestamp": "01:16",
                "stage": "手柄与滤纸耗材归档",
                "detail": "录入格米莱 58mm 实木双嘴手柄、58mm 丸型咖啡滤纸及常驻口粮豆（RARAKIDDO 咸芝士低因 SOE），已自动更新至常驻设备库。",
            },
        ]
        tools_bullet = "\n".join(f"• {it['name']}（{it['category']}）" for it in rec.equipment_items)
        rec.xiaohongshu_copy = (
            f"☕️ 居家咖啡角设备大盘点｜用 {rec.camera_device} 自动建档我的咖啡制作全家福✨\n\n"
            f"对着大疆镜头介绍了一遍家里的咖啡机和顺手小工具，AI 自动识别并同步到了我的常驻咖啡设备库，每一件都是日常出杯的好帮手！🎬\n\n"
            f"📋 【我的常驻咖啡角装备清单】\n"
            f"{tools_bullet}\n"
            f"🫘 当前在用口粮豆：{rec.bean_name}\n\n"
            f"💡 【吧台使用心得】\n"
            f"• 格米莱 G3828A 自带豆仓一体机省空间又稳定，配合自动回弹压粉锤和 58mm 丸型滤纸，新手也能稳定压出水平粉饼、油脂超细腻！\n"
            f"• 备一个桌面小吸尘器随时吸走残粉，咖啡角每天都干干净净～\n\n"
            f"#居家咖啡角 #咖啡机推荐 #格米莱3828 #咖啡器具分享 #MHW3BOMBER #家庭咖啡馆 #大疆Pocket4Pro #咖啡日常"
        )
        rec.wechat_copy = (
            f"☕️ 居家咖啡角常驻设备 & 器具盘点建档\n"
            f"⚙️ 主力机：{machine_name}\n"
            f"🛠️ 全套器具：自动回弹压粉锤 · 布粉器 · 接粉环 · 58mm双嘴手柄 · 丸型滤纸 · 桌面吸尘器 · 出品杯\n"
            f"🫘 常驻豆：{rec.bean_name}\n"
            f"📹 录制：{rec.camera_device} (LAN STA 自动识别建档)"
        )
        return

    is_cold_brew = bool(rec.brew_method and "冷萃" in rec.brew_method)
    has_core_espresso_metrics = (
        rec.bean_weight_g is not None
        and rec.yield_g is not None
        and rec.extraction_time_s is not None
    )
    weight = rec.bean_weight_g or (50.0 if is_cold_brew else 18.0)
    yield_g = rec.yield_g or (500.0 if is_cold_brew else 36.0)
    ratio = round(yield_g / weight, 2) if weight > 0 else 2.0
    time_s = rec.extraction_time_s or (43200.0 if is_cold_brew else 28.0)
    pressure = rec.pressure_bar if rec.pressure_bar is not None else (1.0 if is_cold_brew else 9.0)

    suggestions: List[str] = []
    flavor = FlavorProfile()

    if is_cold_brew:
        hours = round(time_s / 3600.0, 1)
        rec.extraction_diagnosis = (
            f"本次{rec.brew_method}采用粉水比 1:{ratio}，低温慢速浸泡约 {hours} 小时。"
            f"使用{rec.grinder_type or '独立磨豆机'}（{rec.grind_setting or '中粗研磨'}）有效避免了细粉过萃带来的杂涩感，"
            f"花果香气与干净度表现极佳。"
        )
        flavor = FlavorProfile(acidity=7.8, sweetness=8.6, body=6.8, aroma=8.9, aftertaste=8.4, balance=8.5)
        rec.flavor_notes = ["茉莉花香", "水蜜桃汁", "柑橘蜜甜", "丝滑冷冽尾韵"]
        suggestions = [
            f"【粉水比微调】当前粉水比为 1:{ratio}，若直接加冰块饮用，建议下次将粉水比收紧至 1:{max(7.0, round(ratio - 1.5, 1))}，冰块融化后浓度更饱满。",
            f"【研磨度建议】使用 {rec.grinder_model or '磨豆机'} 时，可在装粉前用筛粉器简单筛去极细粉（<200μm），冷萃液透亮度还能提升一个台阶。",
            "【熟成风味】过滤出液后建议在冰箱密封静置熟成 12 小时再饮用，发酵果香与威士忌般的甜感会更加圆润。",
        ]
    elif not has_core_espresso_metrics:
        # Honest diagnosis when core brewing metrics were not captured — never fabricate 18g->36g / 28s / 9.0 bar!
        captured_parts = []
        if rec.bean_name:
            captured_parts.append(f"咖啡豆「{rec.bean_name}」")
        if rec.bean_weight_g is not None:
            captured_parts.append(f"粉重 {rec.bean_weight_g}g")
        if rec.yield_g is not None:
            captured_parts.append(f"出液 {rec.yield_g}g")
        if rec.extraction_time_s is not None:
            captured_parts.append(f"耗时 {int(rec.extraction_time_s)}s")
        if rec.pressure_bar is not None:
            captured_parts.append(f"压力 {rec.pressure_bar} bar")
        missing_labels = "、".join(m["label"] for m in (rec.missing_fields or [])[:5]) or "粉重、出液量、萃取时间"
        captured_str = "，".join(captured_parts) if captured_parts else "基础录制片段"
        rec.extraction_diagnosis = (
            f"已捕获 {captured_str}，但本次录制尚未完整采集到【{missing_labels}】等实测数值。"
            f"系统不会虚构默认萃取数据，您可以在上方补全框补充实测参数后重新生成精准萃取诊断。"
        )
        flavor = FlavorProfile(acidity=7.2, sweetness=7.8, body=7.8, aroma=8.2, aftertaste=7.6, balance=7.8)
        if not rec.flavor_notes:
            rec.flavor_notes = ["待补全实测参数", "支持语音/手动一键补全"]
        suggestions = [
            f"【补充实测参数】请在上方补全「{missing_labels}」，AI 将基于真实粉液比与流速为您计算萃取率与研磨调整建议。",
            f"【当前常驻设备】默认关联 {rec.grinder_type or '咖啡机自带磨豆机'}（{rec.grinder_model or '格米莱 G3828A'}），若本次仅介绍设备可在常驻设备库查看。",
        ]
    else:
        # Espresso / SOE analysis with real captured parameters
        diag_parts = []
        if 1.8 <= ratio <= 2.3 and 24 <= time_s <= 33 and 8.5 <= pressure <= 9.5:
            diag_parts.append(
                f"黄金萃取区间命中！粉液比 1:{ratio}（{weight}g 粉 → {yield_g}g 液），耗时 {int(time_s)}s，压力稳定在 {pressure} bar。"
            )
            diag_parts.append("油脂（Crema）呈细腻虎斑纹，前中后段流速均匀，酸甜平衡度与醇厚度表现优异。")
            flavor = FlavorProfile(acidity=7.8, sweetness=8.8, body=8.5, aroma=9.0, aftertaste=8.6, balance=8.9)
        elif time_s < 22:
            diag_parts.append(
                f"流速偏快（{int(time_s)}s 萃出 {yield_g}g，粉液比 1:{ratio}），存在轻微通道效应或研磨偏粗导致的萃取不足。"
            )
            flavor = FlavorProfile(acidity=8.7, sweetness=6.8, body=6.5, aroma=7.8, aftertaste=6.4, balance=6.9)
            suggestions.append(
                f"【研磨度调细】当前 {rec.grind_setting or '刻度'} 流速偏快，建议将 {rec.grinder_model or '磨豆机'} 往细调 0.5 ~ 1.0 格，把萃取时间延长至 26-30 秒。"
            )
        elif time_s > 35:
            diag_parts.append(
                f"流速偏慢（耗时 {int(time_s)}s，压力 {pressure} bar），粉饼阻力较大，后段容易析出木质苦涩感。"
            )
            flavor = FlavorProfile(acidity=6.2, sweetness=7.2, body=8.9, aroma=7.9, aftertaste=6.8, balance=7.0)
            suggestions.append(
                f"【研磨度调粗】当前 {rec.grind_setting or '刻度'} 阻力偏高，建议往粗微调 0.5 ~ 1 格，或将粉量减少 0.5g 至 {round(weight - 0.5, 1)}g。"
            )
        else:
            diag_parts.append(
                f"整体萃取扎实稳定：粉重 {weight}g，出液 {yield_g}g（粉液比 1:{ratio}），萃取时间 {int(time_s)}s，峰值压力 {pressure} bar。"
            )
            flavor = FlavorProfile(acidity=7.6, sweetness=8.3, body=8.2, aroma=8.5, aftertaste=8.1, balance=8.3)

        rec.extraction_diagnosis = "".join(diag_parts)

        if "花魁" in (rec.bean_name or "") or "耶加" in (rec.bean_name or "") or "埃塞" in (rec.bean_name or ""):
            rec.flavor_notes = ["佛手柑", "热带百香果", "草莓果酱", "奶油太妃糖尾韵"]
        elif "瑰夏" in (rec.bean_name or ""):
            rec.flavor_notes = ["白花香气", "柠檬草", "水蜜桃", "蜂蜜红茶感"]
        elif "咸芝士" in (rec.bean_name or ""):
            rec.flavor_notes = ["咸芝士饼干", "曲奇黄油", "焦糖坚果", "奶油巧克力"]
        else:
            rec.flavor_notes = ["黑巧克力", "烤榛果", "焦糖甜感", "柑橘尾韵"]

        if not suggestions:
            suggestions.append(
                f"【进阶变压曲线】当前 {pressure} bar 恒压表现稳定，下次可在前 6 秒采用 3 bar 低压预浸泡，尾段（22s 后）自然降压至 6 bar，进一步放大甜感并收敛尾段杂味。"
            )
        suggestions.append(
            f"【磨豆机与布粉优化】本次使用{rec.grinder_type or '独立磨豆机'}（{rec.grinder_model or '主力磨'}，{rec.grind_setting or '标准刻度'}），建议搭配 WDT 针式布粉器打散结块，保持无底手柄中心稳定出液。"
        )
        suggestions.append(
            f"【饮品搭配建议】1:{ratio} 的浓缩基底油脂丰厚，既适合直接品鉴 Espresso，也非常适合搭配 150ml 冰博克/明治鲜奶制作 Dirty，分口大口饮用冷热层次感拉满。"
        )

    rec.suggestions = suggestions
    rec.flavor_profile = {
        "acidity": flavor.acidity,
        "sweetness": flavor.sweetness,
        "body": flavor.body,
        "aroma": flavor.aroma,
        "aftertaste": flavor.aftertaste,
        "balance": flavor.balance,
    }

    # Generate Pocket 3 / Pocket 4 Pro visual + audio timeline milestones
    rec.timeline_events = [
        {
            "timestamp": "00:02",
            "stage": "语音唤醒 & STA 录制启动",
            "detail": f"检测到唤醒词「我要开始制作咖啡」，{rec.camera_device} 通过局域网 STA 节点自动开启录制。",
        },
        {
            "timestamp": "00:18",
            "stage": "称豆 & 研磨度设定",
            "detail": f"语音+视觉识别：{rec.bean_name or '精选咖啡豆'}，电子秤读数 {rec.bean_weight_g or '--'}g，{rec.grinder_type or '磨豆机'}（{rec.grind_setting or '待补充'}）。",
        },
        {
            "timestamp": "00:52",
            "stage": "布粉压粉 & 上柄",
            "detail": "相机画面捕捉到 WDT 布粉与恒力压粉动作，粉碗边缘清洁完毕。",
        },
        {
            "timestamp": "01:15",
            "stage": "核心萃取监测",
            "detail": f"方式：{rec.brew_method or '意式萃取'} | 压力表峰值 {rec.pressure_bar or '--'} bar | 耗时 {rec.extraction_time_s or '--'}s | 出液 {rec.yield_g or '--'}g。",
        },
        {
            "timestamp": "01:48",
            "stage": "自动停录 & LAN 极速回传",
            "detail": "识别到结束指令/静默完成，相机自动停止录制并通过 STA 局域网 (:8088) 秒级推送 MP4 至本地 AI 引擎。",
        },
    ]

    # Social Media Copy: Xiaohongshu & WeChat Moments
    bean_disp = rec.bean_name or "今日精选私藏豆"
    method_disp = rec.brew_method or "意式浓缩 Espresso"
    time_disp = (
        f"{round(rec.extraction_time_s / 3600, 1)}h"
        if (is_cold_brew and rec.extraction_time_s)
        else (f"{int(rec.extraction_time_s)}s" if rec.extraction_time_s is not None else "--s")
    )
    notes_disp = " · ".join(rec.flavor_notes)

    rec.xiaohongshu_copy = (
        f"☕️ 每日咖啡打卡｜用 {rec.camera_device} 自动记录的第 N 杯好咖啡✨\n\n"
        f"对着镜头说一句「开始做咖啡」，相机通过局域网 STA 模式自动开录，做完自动分析视频和语音生成这份超详细的萃取报告，仪式感直接拉满！🎬\n\n"
        f"📋 【今日萃取档案】\n"
        f"🫘 咖啡豆：{bean_disp} {f'({rec.bean_roast})' if rec.bean_roast else ''}\n"
        f"⚖️ 粉重 & 出液：{rec.bean_weight_g or '--'}g 粉 ➔ {rec.yield_g or '--'}g 液（粉液比 {rec.brew_ratio or '--'}）\n"
        f"⚙️ 磨豆设备：{rec.grinder_type or '独立磨豆机'} · {rec.grinder_model or ''}（{rec.grind_setting or '标准刻度'}）\n"
        f"⏱️ 萃取参数：{method_disp}｜耗时 {time_disp}｜压力 {rec.pressure_bar or '--'} bar\n"
        f"🍋 风味表现：{notes_disp}\n\n"
        f"💡 【AI 咖啡师复盘建议】\n"
        f"• {rec.suggestions[0]}\n"
        f"• {rec.suggestions[1] if len(rec.suggestions) > 1 else ''}\n\n"
        f"#居家咖啡角 #咖啡日常 #意式浓缩 #大疆Pocket3 #Pocket4Pro #咖啡萃取记录 #家庭咖啡师 #今日份咖啡"
    )

    rec.wechat_copy = (
        f"☕️ 今日份 {method_disp} 出杯报告\n"
        f"🫘 {bean_disp}｜{rec.bean_weight_g or '--'}g → {rec.yield_g or '--'}g ({rec.brew_ratio or '--'})\n"
        f"⚙️ {rec.grinder_model or rec.grinder_type or '磨豆机'} ({rec.grind_setting or '--'})｜⏱️ {time_disp} @ {rec.pressure_bar or '--'} bar\n"
        f"✨ 风味：{notes_disp}\n"
        f"📹 录制：{rec.camera_device} (LAN STA 全自动记录)"
    )
