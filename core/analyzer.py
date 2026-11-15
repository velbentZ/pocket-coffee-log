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


def parse_cn_or_float(val_str: str) -> Optional[float]:
    val_str = val_str.strip()
    try:
        return float(val_str)
    except ValueError:
        pass
    # Simple Chinese number parser (e.g. 十八 -> 18, 二十八 -> 28, 九点五 -> 9.5)
    if "点" in val_str:
        parts = val_str.split("点", 1)
        left = parse_cn_or_float(parts[0])
        right_digits = "".join(str(CN_NUMS.get(c, c)) for c in parts[1])
        try:
            return float(f"{int(left or 0)}.{right_digits}")
        except ValueError:
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
    rec = CoffeeRecord(
        camera_device=camera_device,
        video_path=video_path,
        transcript=transcript.strip(),
    )
    text = transcript

    # 1. Brew method (做的是意式浓缩还是冷萃 / 美式 / 拿铁 / 手冲 / Dirty)
    if any(k in text for k in ["冷萃", "冰滴", "Cold Brew", "cold brew"]):
        if "冰滴" in text:
            rec.brew_method = "冰滴冷萃 (Ice Drip Cold Brew)"
        else:
            rec.brew_method = "冷萃咖啡 (Cold Brew)"
    elif any(k in text for k in ["意式浓缩", "浓缩", "Espresso", "espresso", "双份浓缩", "Double", "SOE", "意式"]):
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
        r"(?:今天做|今天冲|今天萃)(?:的是|一杯)?([^，。；！\n]{3,25}?(?:豆|耶加雪菲|花魁|瑰夏|西达摩|曼特宁|肯尼亚|哥伦比亚|埃塞|拼配|SOE))",
        r"((?:埃塞俄比亚|巴拿马|哥伦比亚|肯尼亚|洪都拉斯|云南|巴西|印尼)[^，。；\n]{2,20})",
        r"((?:花魁|瑰夏|耶加雪菲|西达摩|天堂庄园|翡翠庄园|栓皮栎|雪莉)[^，。；\n]{0,14})",
    ]
    for pat in bean_patterns:
        m = re.search(pat, text)
        if m:
            candidate = m.group(1).strip()
            # Clean trailing filler words
            candidate = re.sub(r"(?:称重|克重|磨豆|研磨).*$", "", candidate).strip(" ，、的")
            if len(candidate) >= 2:
                rec.bean_name = candidate
                break

    if "中浅烘" in text:
        rec.bean_roast = "中浅烘焙"
    elif "浅烘" in text:
        rec.bean_roast = "浅度烘焙"
    elif "中深烘" in text:
        rec.bean_roast = "中深烘焙"
    elif "深烘" in text:
        rec.bean_roast = "深度烘焙"
    elif "中烘" in text:
        rec.bean_roast = "中度烘焙"

    # 3. Bean weight (咖啡豆称重是多少)
    weight_patterns = [
        r"(?:咖啡豆|豆子|粉量|称重|装粉|用了|称了)[^0-9一二两三四五六七八九十，。]{0,12}?([0-9]+(?:\.[0-9]+)?|[一二两三四五六七八九十点]+)\s*(?:克|g|G)",
        r"([0-9]+(?:\.[0-9]+)?)\s*(?:克|g|G)\s*(?:咖啡豆|豆子|粉)",
        r"(?:瑰夏|花魁|耶加|西达摩|曼特宁|拼配|豆)\s*([0-9]+(?:\.[0-9]+)?)\s*(?:克|g|G)",
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
        r"(?:研磨度|刻度|磨豆刻度|刀盘刻度|粗细)(?:调到|设置在|是|用|为|调成)?\s*([0-9]+(?:\.[0-9]+)?(?:\s*格|\s*圈|\s*档)?|[一二三四五六七八九十点]+(?:格|档)?)",
        r"刻度\s*([0-9]+(?:\.[0-9]+)?)",
    ]
    for pat in grind_patterns:
        m = re.search(pat, text)
        if m:
            rec.grind_setting = f"刻度 {m.group(1).strip()}"
            break

    # 5. Grinder type & model (额外的磨豆机还是咖啡机自身自带的)
    external_models = ["Niche Zero", "Niche", "DF64", "DF83", "マイト", "迈赫迪", "EK43", "Weber", "EG-1", "Lagom", "P64", "P100", "C40", "司令官", "Eureka", "Mignon", "松屋", "巫师"]
    found_model = None
    for mod in external_models:
        if mod.lower() in text.lower():
            found_model = mod
            break

    if any(k in text for k in ["自带磨豆机", "自带的磨豆机", "咖啡机自带", "内置磨豆机", "一体机自带"]):
        rec.grinder_type = "咖啡机自带磨豆机"
        if "铂富" in text or "Breville" in text.lower():
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
        r"(?:出液量?|萃取液|液重|出杯量?|萃出|流出了?|接了|注水|加水)[^0-9一二两三四五六七八九十]{0,6}([0-9]+(?:\.[0-9]+)?|[一二两三四五六七八九十点]+)\s*(?:克|毫升|g|G|ml|ML)",
        r"([0-9]+(?:\.[0-9]+)?)\s*(?:克|毫升|g|ml)\s*(?:咖啡液|浓缩液|出液)",
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
    hour_m = re.search(r"(?:萃取|浸泡|冷藏|时间)[^0-9]{0,6}([0-9]+(?:\.[0-9]+)?)\s*(?:小时|h|H)", text)
    sec_m = re.search(r"(?:萃取时间|萃取了?|耗时|读秒|用了|时间是?)[^0-9一二两三四五六七八九十]{0,6}([0-9]+(?:\.[0-9]+)?|[一二两三四五六七八九十]+)\s*(?:秒|s|S)", text)
    if not sec_m:
        sec_m = re.search(r"([0-9]{2}(?:\.[0-9]+)?)\s*(?:秒|s)\s*(?:出液|结束|完成|停)", text)

    if sec_m:
        rec.extraction_time_s = parse_cn_or_float(sec_m.group(1))
    elif hour_m:
        hours = parse_cn_or_float(hour_m.group(1))
        if hours:
            rec.extraction_time_s = round(hours * 3600, 1)

    # 8. Pressure (萃取压力是多少 bar)
    pressure_m = re.search(
        r"(?:压力表?|萃取压力|峰值压力|压力)(?:稳定在|在|是|达到|为)?\s*([0-9]+(?:\.[0-9]+)?|[一二三四五六七八九十点]+)\s*(?:bar|Bar|BAR|帕|巴)",
        text,
    )
    if not pressure_m:
        pressure_m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*(?:bar|Bar|BAR|巴)", text)
    if pressure_m:
        rec.pressure_bar = parse_cn_or_float(pressure_m.group(1))

    # 9. Water temperature
    temp_m = re.search(r"(?:水温|萃取温度|温度)[^0-9]{0,4}([0-9]+(?:\.[0-9]+)?)\s*(?:度|°C|℃)", text)
    if temp_m:
        rec.water_temp_c = float(temp_m.group(1))

    # Apply visual overrides if detected from camera frames
    if visual_Overrides:
        for k, v in visual_Overrides.items():
            if getattr(rec, k, None) is None and v is not None:
                setattr(rec, k, v)

    rec.compute_derived_metrics()
    enrich_barista_analysis(rec)
    return rec


def enrich_barista_analysis(rec: CoffeeRecord) -> None:
    """
    Generates professional barista diagnosis, flavor profile scores, timeline events,
    next-brew optimization suggestions, and Xiaohongshu / WeChat social share copy.
    """
    is_cold_brew = bool(rec.brew_method and "冷萃" in rec.brew_method)
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
    else:
        # Espresso / SOE analysis
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
    time_disp = f"{round(time_s / 3600, 1)}h" if is_cold_brew else f"{int(time_s)}s"
    notes_disp = " · ".join(rec.flavor_notes)

    rec.xiaohongshu_copy = (
        f"☕️ 每日咖啡打卡｜用 {rec.camera_device} 自动记录的第 N 杯好咖啡✨\n\n"
        f"对着镜头说一句「开始做咖啡」，相机通过局域网 STA 模式自动开录，做完自动分析视频和语音生成这份超详细的萃取报告，仪式感直接拉满！🎬\n\n"
        f"📋 【今日萃取档案】\n"
        f"🫘 咖啡豆：{bean_disp} {f'({rec.bean_roast})' if rec.bean_roast else ''}\n"
        f"⚖️ 粉重 & 出液：{rec.bean_weight_g or '--'}g 粉 ➔ {rec.yield_g or '--'}g 液（粉液比 {rec.brew_ratio or '1:2.0'}）\n"
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
        f"🫘 {bean_disp}｜{rec.bean_weight_g or '--'}g → {rec.yield_g or '--'}g ({rec.brew_ratio or '1:2'})\n"
        f"⚙️ {rec.grinder_model or rec.grinder_type or '磨豆机'} ({rec.grind_setting or '--'})｜⏱️ {time_disp} @ {rec.pressure_bar or '--'} bar\n"
        f"✨ 风味：{notes_disp}\n"
        f"📹 录制：{rec.camera_device} (LAN STA 全自动记录)"
    )
