"""
Pocket Coffee Log HTTP API & Web Server.

Provides REST endpoints for:
- `/api/state`: Full dashboard state (coffee records, active voice session, camera STA nodes, notification logs)
- `/api/camera/sta`: Verified camera STA and automatic recovery status
- `/api/camera/auto_recover`: Request an immediate stale-heartbeat check
- `/api/camera/media`: Latest camera media info & `:8088` remote DCIM file listing
- `/api/camera/pull_media`: Pull latest `.MP4` from camera `:8088` and extract 4-stage keyframes
- `/api/camera/gimbal`: Move Pocket 3 / Pocket 4 Pro gimbal between OsmoDesk brew presets (`P0`–`P4`)
- `/api/beans/scan_label`: Parse natural language / OCR coffee bag label text into Bean Library
- `/api/records/compare`: Visualizer / Beanconqueror style side-by-side shot comparison (`?bean=...`)
- `/api/voice/utterance`: Feed spoken voice transcript ("我要开始制作咖啡...", parameter narration, "制作完成")
- `/api/voice/stop`: Manually or automatically stop recording and trigger AI report generation
- `/api/records/supplement`: Fill in missing coffee parameters from mobile notification reminder
- `/api/camera/provision_sta`: Switch Pocket 3 / Pocket 4 Pro into persistent LAN STA mode & deploy internal agent
- `/api/camera/exec`: Execute root shell commands inside the camera over USB/LAN ADB
- `/api/camera/shutter`: Trigger LAN DUML [02:02] Start/Stop recording
- `/api/camera/webhook`: Receive automatic webhook from `/data/pocket-coffee/pocket_sta_agent.sh` inside camera when MP4 closes
- `/api/notifications/config`: Update WeCom / ServerChan / Bark / Feishu push credentials
"""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from array import array
import base64
import binascii
import io
import ipaddress
import math
import tempfile
import time
import wave
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, quote, urlparse

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.analyzer import enrich_barista_analysis, extract_parameters_from_transcript
from core.bean_equipment_store import BeanAndEquipmentManager
from core.camera_sta_bridge import CameraInternalBridge, _is_safe_camera_http_url
from core.context_engine import ProjectMemoryManager, SessionContextCompactor
from core.media_upload import ALLOWED_MEDIA_EXTENSIONS, guess_media_mime, parse_multipart_upload
from core.multimodal_vision import MultimodalVisionEngine
from core.notifier import (
    NotificationManager,
    REDACTED_SECRET_PLACEHOLDER,
    SECRET_NOTIFICATION_KEYS,
    redact_notification_config,
    validate_notification_config,
)
from core.pipeline import CoffeeIngestionPipeline
from core.registry import global_event_bus, global_registry
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager


DATA_DIR = os.path.join(PROJECT_ROOT, "data")
STATIC_DIR = os.path.join(PROJECT_ROOT, "static")

for _tmp_var in ("TMPDIR", "TEMP", "TMP"):
    _tmp_val = os.environ.get(_tmp_var)
    if _tmp_val and not os.path.isdir(_tmp_val):
        os.environ.pop(_tmp_var, None)
tempfile.tempdir = None

for _proxy_var in ("NO_PROXY", "no_proxy"):
    os.environ[_proxy_var] = "*"

store = CoffeeStore(DATA_DIR)
camera_bridge = CameraInternalBridge(DATA_DIR)
notifier = NotificationManager(DATA_DIR)
bean_manager = BeanAndEquipmentManager(DATA_DIR)
vision_engine = MultimodalVisionEngine(DATA_DIR)
memory_manager = ProjectMemoryManager(PROJECT_ROOT)
compactor = SessionContextCompactor()
ingestion_pipeline = CoffeeIngestionPipeline(store, vision_engine, bean_manager, notifier, compactor)
voice_manager = VoiceWakeupSessionManager(store, camera_bridge, notifier)

# Register decoupled core modules in global ModuleRegistry
global_registry.register("capture_source", "dji_duml_sta", camera_bridge, {"models": ["Pocket 3", "Pocket 4 Pro"], "optional": True})
global_registry.register("capture_source", "multi_device_upload", ingestion_pipeline, {"devices": ["iPhone", "iPad", "Mac", "Android", "Web"], "formats": ["video", "audio", "text"]})
global_registry.register("recognition", "multimodal_vision_speech", vision_engine, {"audio_asr": True, "video_ocr_vlm": True, "vlm": vision_engine.vlm_provider})
global_registry.register("report_generator", "coffee_ingestion_pipeline", ingestion_pipeline, {"record_types": ["brew_report", "equipment_profile"]})
global_registry.register("bean_equipment", "bean_equipment_manager", bean_manager, {"inventory": True, "equipment_profile": True})
# Legacy registry categories preserved for backwards compatibility
global_registry.register("camera_driver", "dji_duml_sta", camera_bridge, {"models": ["Pocket 3", "Pocket 4 Pro"], "mode": "single_active_rotation"})
global_registry.register("extractor", "multimodal_cn_regex", extract_parameters_from_transcript, {"lossless": True})
global_registry.register("extractor", "whisper_vlm_keyframes", vision_engine, {"vlm": vision_engine.vlm_provider})
global_registry.register("advisor", "barista_flavor_advisor", enrich_barista_analysis, {"radar_axes": 6})
global_registry.register("advisor", "bean_equipment_feedback_loop", bean_manager, {"subjective_calibration": True})
global_registry.register("notifier", "multi_channel_dispatcher", notifier, {"channels": ["WeCom", "ServerChan", "Bark", "Feishu"]})

# Ensure initial notifications are seeded for the sample records if history is empty
if not notifier.get_history():
    for rec in reversed(store.list_records()):
        notifier.notify_brew_record(rec)


def _extract_first_float(val: Any) -> Optional[float]:
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)
    m = re.search(r"([0-9]+(?:\.[0-9]+)?)", str(val))
    return float(m.group(1)) if m else None


def _extract_ratio_value(rec_dict: Dict[str, Any]) -> Optional[float]:
    ratio_str = rec_dict.get("brew_ratio") or ""
    if ":" in str(ratio_str):
        right = str(ratio_str).split(":", 1)[1]
        parsed = _extract_first_float(right)
        if parsed is not None:
            return parsed
    w = rec_dict.get("bean_weight_g")
    y = rec_dict.get("yield_g")
    if isinstance(w, (int, float)) and w > 0 and isinstance(y, (int, float)):
        return round(float(y) / float(w), 2)
    return None


def build_shot_comparison(
    records: List[Dict[str, Any]],
    bean: str = "",
    brew_method: str = "",
    left_id: str = "",
    right_id: str = "",
) -> Dict[str, Any]:
    """
    Beanconqueror / Visualizer.coffee inspired side-by-side shot comparison.
    Compares historical brews of the same bean or brew method across dose weight,
    grind setting, yield, brew ratio, extraction time, pressure, and 6-axis flavor radar.
    """
    bean_q = (bean or "").strip()
    method_q = (brew_method or "").strip()

    matched = list(records)
    if bean_q:
        matched = [r for r in matched if bean_q.lower() in (r.get("bean_name") or "").lower()]
    if method_q:
        matched = [r for r in matched if method_q.lower() in (r.get("brew_method") or "").lower()]

    by_id = {r.get("id"): r for r in records if r.get("id")}
    baseline_shot: Optional[Dict[str, Any]] = by_id.get(left_id) if left_id else None
    latest_shot: Optional[Dict[str, Any]] = by_id.get(right_id) if right_id else None

    if latest_shot is None and matched:
        latest_shot = matched[0]
    if baseline_shot is None:
        if len(matched) >= 2:
            baseline_shot = matched[1] if matched[0].get("id") == (latest_shot or {}).get("id") else matched[0]
        elif matched:
            baseline_shot = matched[0]

    if not baseline_shot or not latest_shot:
        return {
            "ok": True,
            "query": {"bean": bean_q, "brew_method": method_q, "left_id": left_id, "right_id": right_id},
            "matched_count": len(matched),
            "records": matched,
            "baseline_shot": baseline_shot,
            "latest_shot": latest_shot,
            "parameter_deltas": {},
            "flavor_radar_delta": {},
            "insights": ["暂无足够的同款咖啡豆或同方式历史记录可供对比。"],
        }

    def num_delta(field: str, unit: str = "") -> Dict[str, Any]:
        b_val = baseline_shot.get(field)
        l_val = latest_shot.get(field)
        d_val = (
            round(float(l_val) - float(b_val), 2)
            if isinstance(b_val, (int, float)) and isinstance(l_val, (int, float))
            else None
        )
        return {"baseline": b_val, "latest": l_val, "delta": d_val, "unit": unit}

    b_grind_str = baseline_shot.get("grind_setting")
    l_grind_str = latest_shot.get("grind_setting")
    b_grind_num = _extract_first_float(b_grind_str)
    l_grind_num = _extract_first_float(l_grind_str)
    grind_delta = (
        round(l_grind_num - b_grind_num, 2)
        if (b_grind_num is not None and l_grind_num is not None)
        else None
    )
    grind_direction = (
        "finer"
        if (grind_delta is not None and grind_delta < 0)
        else ("coarser" if (grind_delta is not None and grind_delta > 0) else "unchanged")
    )

    b_ratio_num = _extract_ratio_value(baseline_shot)
    l_ratio_num = _extract_ratio_value(latest_shot)
    ratio_delta = (
        round(l_ratio_num - b_ratio_num, 2)
        if (b_ratio_num is not None and l_ratio_num is not None)
        else None
    )

    parameter_deltas = {
        "bean_weight_g": num_delta("bean_weight_g", "g"),
        "grind_setting": {
            "baseline": b_grind_str,
            "latest": l_grind_str,
            "baseline_num": b_grind_num,
            "latest_num": l_grind_num,
            "delta": grind_delta,
            "direction": grind_direction,
        },
        "yield_g": num_delta("yield_g", "g"),
        "brew_ratio": {
            "baseline": baseline_shot.get("brew_ratio"),
            "latest": latest_shot.get("brew_ratio"),
            "baseline_num": b_ratio_num,
            "latest_num": l_ratio_num,
            "delta": ratio_delta,
        },
        "extraction_time_s": num_delta("extraction_time_s", "s"),
        "pressure_bar": num_delta("pressure_bar", "bar"),
        "water_temp_c": num_delta("water_temp_c", "°C"),
    }

    radar_axes = [
        ("acidity", "酸质"),
        ("sweetness", "甜感"),
        ("body", "醇厚度"),
        ("aroma", "香气"),
        ("aftertaste", "余韵"),
        ("balance", "平衡感"),
    ]
    b_fp = baseline_shot.get("flavor_profile") or {}
    l_fp = latest_shot.get("flavor_profile") or {}
    flavor_radar_delta: Dict[str, Dict[str, Any]] = {}
    for axis, label in radar_axes:
        bv = round(float(b_fp.get(axis, 0.0)), 2)
        lv = round(float(l_fp.get(axis, 0.0)), 2)
        flavor_radar_delta[axis] = {
            "label": label,
            "baseline": bv,
            "latest": lv,
            "delta": round(lv - bv, 2),
        }

    insights: List[str] = []
    if baseline_shot.get("id") == latest_shot.get("id"):
        insights.append("当前仅匹配到 1 杯记录，再做一杯同款豆即可查看参数微调前后的萃取演化差值。")
    else:
        if grind_delta is not None and grind_delta != 0:
            dir_cn = "调细" if grind_delta < 0 else "调粗"
            insights.append(f"研磨刻度由「{b_grind_str}」{dir_cn}至「{l_grind_str}」(Δ {grind_delta:+.2f})。")
        t_delta = parameter_deltas["extraction_time_s"]["delta"]
        if t_delta is not None and t_delta != 0:
            insights.append(
                f"萃取时间由 {baseline_shot.get('extraction_time_s')}s 变为 {latest_shot.get('extraction_time_s')}s (Δ {t_delta:+.1f}s)。"
            )
        if ratio_delta is not None and ratio_delta != 0:
            insights.append(
                f"粉液比由 {baseline_shot.get('brew_ratio') or f'1:{b_ratio_num}'} 调整为 {latest_shot.get('brew_ratio') or f'1:{l_ratio_num}'} (Δ {ratio_delta:+.2f})。"
            )
        sw_delta = flavor_radar_delta["sweetness"]["delta"]
        bal_delta = flavor_radar_delta["balance"]["delta"]
        if sw_delta != 0 or bal_delta != 0:
            insights.append(
                f"感官雷达变化：甜感 {sw_delta:+.1f}、平衡感 {bal_delta:+.1f}、醇厚度 {flavor_radar_delta['body']['delta']:+.1f}。"
            )
        if not insights:
            insights.append("两杯核心萃取参数保持高度一致，出品稳定性优异。")

    return {
        "ok": True,
        "query": {"bean": bean_q, "brew_method": method_q, "left_id": left_id, "right_id": right_id},
        "matched_count": len(matched),
        "records": matched,
        "baseline_shot": baseline_shot,
        "latest_shot": latest_shot,
        "parameter_deltas": parameter_deltas,
        "flavor_radar_delta": flavor_radar_delta,
        "insights": insights,
    }


VOICE_CHUNK_MAX_BODY = 512 * 1024
VOICE_CHUNK_MAX_FRAMES = 160000


def _camera_voice_chunk(body):
    if not isinstance(body, dict):
        raise ValueError("Expected a JSON object")
    device_id = body.get("device_id")
    recording = body.get("recording_active")
    encoded = body.get("wav_b64")
    if device_id not in ("pocket4p", "pocket3") or type(recording) is not bool or not isinstance(encoded, str):
        raise ValueError("Expected device_id, boolean recording_active and wav_b64")
    try:
        raw = base64.b64decode(encoded, validate=True)
        with wave.open(io.BytesIO(raw), "rb") as wav:
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 16000):
                raise ValueError("Expected mono 16 kHz signed 16-bit PCM WAV")
            frames = wav.readframes(VOICE_CHUNK_MAX_FRAMES + 1)
        if len(frames) % 2 or len(frames) > VOICE_CHUNK_MAX_FRAMES * 2:
            raise ValueError("Invalid camera WAV length")
    except (binascii.Error, EOFError, wave.Error, UnicodeError) as exc:
        raise ValueError("Invalid camera WAV") from exc

    samples = array("h", frames)
    if sys.byteorder != "little":
        samples.byteswap()
    transcript, command = "", "none"
    if samples:
        dc_offset = sum(samples) / len(samples)
        centered = [sample - dc_offset for sample in samples]
        amplitudes = sorted(map(abs, centered))
        p99_abs = amplitudes[(99 * len(amplitudes) - 1) // 100]
        if p99_abs < 2000:
            # Ignore sparse PulseAudio clipping before measuring speech or setting gain.
            spike_threshold = max(8000, 4 * p99_abs)
            centered = [0 if abs(sample) > spike_threshold else sample for sample in centered]

        peak_clean = max(map(abs, centered))
        # Check 50 ms windows so a brief word is not averaged into the entire clip.
        if peak_clean >= 25 and any(
            sum(sample * sample for sample in window) >= len(window) * 6**2
            for window in (centered[i:i + 800] for i in range(0, len(centered), 800))
        ):
            gain = min(80.0, 16000.0 / peak_clean) if peak_clean < 12000 else 1.0
            normalized = array("h", (
                max(-32767, min(32767, round(sample * gain))) for sample in centered
            ))
            if sys.byteorder != "little":
                normalized.byteswap()
            os.makedirs(DATA_DIR, exist_ok=True)
            with tempfile.NamedTemporaryFile(suffix=".wav", dir=DATA_DIR) as audio:
                with wave.open(audio, "wb") as wav:
                    wav.setparams((1, 2, 16000, 0, "NONE", ""))
                    wav.writeframes(normalized.tobytes())
                audio.flush()
                transcript = vision_engine.extract_audio_and_transcribe(audio.name).strip()
            if transcript:
                command = voice_manager.handle_camera_transcript(device_id, transcript, recording)
                print(f"[CameraMic] {device_id}: transcript={transcript!r} -> command={command}", flush=True)
    return {"ok": True, "transcript": transcript, "command": command, "action_token": f"ACTION:{command.upper()}"}


MAX_JSON_BODY_BYTES = 2 * 1024 * 1024
ALLOWED_KEYFRAME_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
SUPPLEMENT_FLOAT_FIELDS = {"bean_weight_g", "yield_g", "extraction_time_s", "pressure_bar", "water_temp_c"}
SUPPLEMENT_STRING_FIELDS = {
    "bean_name",
    "bean_roast",
    "grind_setting",
    "grinder_type",
    "grinder_model",
    "brew_method",
}
ALLOWED_TASTE_TAGS = {"balanced_sweet", "too_sour", "too_bitter", "watery"}
ALLOWED_EQUIPMENT_FIELDS = {
    "default_grinder_type",
    "default_grinder_model",
    "secondary_grinder_model",
    "espresso_machine",
    "default_water_temp_c",
    "auto_fill_default_grinder",
}
ALLOWED_DIAGNOSTIC_SHELL_SNIPPETS = {
    "id",
    "uname -a",
    "ps",
    "iw dev",
    "iw dev wlan0 info",
    "ip -4 addr",
    "ip -4 addr show wlan0",
    "wpa_cli interfaces",
    "wpa_cli -p /data/misc/wifi/sockets -i wlan0 status",
    "ls -la /mnt/media_rw/emulated/DCIM/DJI_001",
}


class _RequestBodyError(ValueError):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


def _is_local_or_lan_host(hostname: str) -> bool:
    host = (hostname or "").strip().lower().rstrip(".")
    if not host:
        return False
    if host == "localhost":
        return True
    if host.endswith(".local"):
        label = host[:-6]
        if not label or len(label) > 63 or "." in label:
            return False
        return bool(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", label))
    try:
        addr = ipaddress.ip_address(host)
        if addr.is_loopback:
            return True
        if addr.is_unspecified or addr.is_link_local or addr.is_multicast or addr.is_reserved:
            return False
        return bool(addr.is_private)
    except ValueError:
        return False


def _sanitize_source_device(raw: Any, fallback: str = "") -> str:
    if raw is None:
        return fallback
    text = str(raw)[:256]
    cleaned_chars: List[str] = []
    for ch in text:
        code = ord(ch)
        if code < 0x20 or (0x7F <= code <= 0x9F):
            if ch in ("\t", "\n", "\r"):
                cleaned_chars.append(" ")
            continue
        if (0x200B <= code <= 0x200F) or (0x202A <= code <= 0x202E) or (0x2066 <= code <= 0x2069) or code == 0xFEFF:
            continue
        cleaned_chars.append(ch)
    collapsed = " ".join("".join(cleaned_chars).split()).strip()
    if not collapsed:
        return fallback
    if collapsed.startswith(("/", "~")) or ".." in collapsed or "://" in collapsed or "\\" in collapsed:
        return fallback
    if re.match(r"^[+-]\d{1,3}(?:\.\d+)?[+-]\d{1,3}(?:\.\d+)?", collapsed):
        return fallback
    return collapsed[:64].strip() or fallback


def _sanitize_client_keyframes(raw_frames: Any, base_dir: str) -> List[Dict[str, Any]]:
    if not isinstance(raw_frames, list):
        return []
    sanitized: List[Dict[str, Any]] = []
    for item in raw_frames[:16]:
        if not isinstance(item, dict):
            continue
        entry: Dict[str, Any] = {}
        for str_key, max_len in (
            ("id", 64),
            ("stage_key", 64),
            ("stage", 120),
            ("preset_badge", 64),
            ("visual_description", 400),
        ):
            val = item.get(str_key)
            if isinstance(val, str) and val.strip():
                entry[str_key] = val.strip()[:max_len]
        for num_key, lo, hi in (("percentage", 0.0, 100.0), ("timestamp_s", 0.0, 86400.0), ("sharpness_score", 0.0, 100000.0)):
            val = item.get(num_key)
            if isinstance(val, (int, float)) and not isinstance(val, bool) and math.isfinite(float(val)):
                clamped = max(lo, min(hi, float(val)))
                entry[num_key] = int(round(clamped)) if num_key == "percentage" else round(clamped, 3)
        raw_fields = item.get("detected_fields")
        if isinstance(raw_fields, dict):
            entry["detected_fields"] = {
                str(k)[:48]: str(v)[:120]
                for k, v in list(raw_fields.items())[:16]
                if v is not None
            }
        raw_ocr = item.get("ocr_texts")
        if isinstance(raw_ocr, list):
            entry["ocr_texts"] = [
                str(line).strip()[:400]
                for line in raw_ocr[:120]
                if isinstance(line, str) and line.strip()
            ]
        raw_img = item.get("image_path")
        safe_img: Optional[str] = None
        if isinstance(raw_img, str) and raw_img.strip():
            safe_img = _resolve_confined_file(raw_img.strip(), base_dir, ALLOWED_KEYFRAME_EXTENSIONS)
        entry["image_path"] = safe_img
        entry["extracted"] = bool(item.get("extracted")) and bool(safe_img)
        sanitized.append(entry)
    return sanitized


def _is_trusted_host_header(raw_host: str) -> bool:
    header = (raw_host or "").strip()
    if not header:
        return True
    if any(ch in header for ch in ("\r", "\n", "\x00", "/", "@")):
        return False
    parsed = urlparse(f"http://{header}")
    host = parsed.hostname or ""
    return _is_local_or_lan_host(host)


def _allowed_cors_origin(raw_origin: str) -> Optional[str]:
    origin = (raw_origin or "").strip()
    if not origin or origin == "null" or any(ch in origin for ch in ("\r", "\n", "\x00")):
        return None
    parsed = urlparse(origin)
    if parsed.scheme not in ("http", "https"):
        return None
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        return None
    if not _is_local_or_lan_host(parsed.hostname or ""):
        return None
    port_suffix = f":{parsed.port}" if parsed.port else ""
    host_out = f"[{parsed.hostname}]" if (parsed.hostname and ":" in parsed.hostname) else (parsed.hostname or "")
    return f"{parsed.scheme}://{host_out}{port_suffix}"


def _resolve_confined_file(rel_or_abs: str, base_dir: str, allowed_extensions: set) -> Optional[str]:
    raw = (rel_or_abs or "").strip()
    if not raw or "\x00" in raw:
        return None
    segments = [seg for seg in raw.replace("\\", "/").split("/") if seg]
    if any(seg == ".." for seg in segments):
        return None
    real_base = os.path.realpath(base_dir)
    cand = os.path.realpath(raw)
    if not (cand.startswith(real_base + os.sep) and os.path.isfile(cand)):
        cand = os.path.realpath(os.path.join(real_base, raw.lstrip("/\\")))
    if not cand.startswith(real_base + os.sep) or not os.path.isfile(cand):
        return None
    ext = os.path.splitext(cand)[1].lower()
    if ext not in allowed_extensions:
        return None
    return cand


def _validate_client_media_reference(
    raw_ref: Any,
    base_dir: str,
    *,
    allow_synthetic_camera_path: bool = False,
) -> Tuple[bool, Optional[str], Optional[str]]:
    if raw_ref is None:
        return True, None, None
    if not isinstance(raw_ref, str):
        return False, None, "Invalid media reference type"
    raw = raw_ref.strip()
    if not raw:
        return True, None, None
    if any(ch in raw for ch in ("\x00", "\r", "\n")):
        return False, None, "Invalid control characters in media reference"
    if raw.startswith(("/api/media/file?", "/api/media/keyframe?")):
        return True, raw, None
    if raw.startswith(("http://", "https://")) or "://" in raw:
        if _is_safe_camera_http_url(raw):
            return True, raw, None
        return False, None, "Unsafe or non-LAN media URL"
    segments = [seg for seg in raw.replace("\\", "/").split("/") if seg]
    if any(seg == ".." for seg in segments):
        return False, None, "Path traversal is not permitted"
    if (
        allow_synthetic_camera_path
        and raw.startswith(("/mnt/media_rw/emulated/DCIM/", "/storage/sdcard0/DCIM/", "/camera/"))
        and not os.path.exists(raw)
    ):
        return True, raw, None
    real_base = os.path.realpath(base_dir)
    cand = os.path.realpath(raw) if os.path.isabs(raw) else os.path.realpath(os.path.join(real_base, raw))
    if not cand.startswith(real_base + os.sep):
        return False, None, "Media path must reside inside the server data directory"
    ext = os.path.splitext(cand)[1].lower()
    if ext not in (ALLOWED_MEDIA_EXTENSIONS | ALLOWED_KEYFRAME_EXTENSIONS):
        return False, None, "Unsupported media file extension"
    return True, cand, None


def _is_loopback_client(ip_str: str) -> bool:
    raw = (ip_str or "").strip()
    if raw in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
        return True
    try:
        return ipaddress.ip_address(raw).is_loopback
    except ValueError:
        return False


def _is_allowed_diagnostic_shell_cmd(cmd: Any) -> bool:
    if not isinstance(cmd, str):
        return False
    stripped = cmd.strip()
    if not stripped or len(stripped) > 256:
        return False
    if any(tok in stripped for tok in (";", "|", "`", "$(", ">", "<", "\n", "\r", "\x00")):
        return False
    parts = [p.strip() for p in stripped.split("&&")]
    if not parts or len(parts) > 4:
        return False
    return all(part in ALLOWED_DIAGNOSTIC_SHELL_SNIPPETS for part in parts)


class CoffeeRequestHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def log_message(self, format: str, *args) -> None:
        # Quiet standard stdout logging
        pass

    def list_directory(self, path: str):
        self.send_error(404, "Directory listing disabled")
        return None

    def end_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("Referrer-Policy", "same-origin")
        cors_origin = _allowed_cors_origin(self.headers.get("Origin", ""))
        if cors_origin:
            self.send_header("Access-Control-Allow-Origin", cors_origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
        super().end_headers()

    def _send_json(self, payload: Dict[str, Any], status: int = 200) -> None:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_json_body(self) -> Dict[str, Any]:
        raw_len = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_len)
        except (TypeError, ValueError):
            raise _RequestBodyError("Invalid Content-Length header", status=400)
        if length < 0:
            raise _RequestBodyError("Negative Content-Length is invalid", status=400)
        if length == 0:
            return {}
        if length > MAX_JSON_BODY_BYTES:
            raise _RequestBodyError(f"JSON request body exceeds {MAX_JSON_BODY_BYTES} bytes", status=413)
        try:
            raw = self.rfile.read(length).decode("utf-8")
            parsed_json = json.loads(raw)
        except (UnicodeDecodeError, ValueError):
            raise _RequestBodyError("Malformed UTF-8 or JSON request body", status=400)
        if not isinstance(parsed_json, dict):
            raise _RequestBodyError("JSON request body must be an object", status=400)
        return parsed_json

    def do_OPTIONS(self) -> None:
        if not _is_trusted_host_header(self.headers.get("Host", "")):
            self._send_json({"ok": False, "error": "Untrusted Host header"}, status=403)
            return
        raw_origin = (self.headers.get("Origin") or "").strip()
        if raw_origin and not _allowed_cors_origin(raw_origin):
            self._send_json({"ok": False, "error": "Origin not allowed"}, status=403)
            return
        self._send_json({"ok": True})

    def do_GET(self) -> None:
        if not _is_trusted_host_header(self.headers.get("Host", "")):
            self._send_json({"ok": False, "error": "Untrusted Host header"}, status=403)
            return
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/api/health":
            self._send_json({"ok": True, "service": "pocket-coffee-log"})
            return

        if path == "/api/records":
            records = [r.to_dict() for r in store.list_records()]
            self._send_json({"ok": True, "records": records})
            return

        if path == "/api/camera/sta":
            self._send_json(camera_bridge.sta_status())
            return

        if path == "/api/camera/media":
            device_id = (qs.get("device_id") or ["pocket4p"])[0]
            cam_state = camera_bridge.load_state()
            cam = cam_state.get("cameras", {}).get(device_id)
            if cam is None:
                self._send_json({"ok": False, "error": f"Unknown camera device_id: {device_id}"}, status=404)
                return

            verification = cam.get("verification") or {}
            lan_ip = verification.get("verified_sta_ip") or cam.get("lan_ip") or ""
            http_media_port = cam.get("http_media_port", 8088)
            latest_media_url = cam.get("latest_media_url") or verification.get("media_http_url") or ""
            latest_media_file = cam.get("latest_media_file") or (
                os.path.basename(latest_media_url) if latest_media_url else ""
            )

            remote_listing: Optional[Dict[str, Any]] = None
            files: List[Dict[str, Any]] = []
            if hasattr(camera_bridge, "list_remote_media"):
                try:
                    remote_listing = camera_bridge.list_remote_media(device_id)
                except TypeError:
                    remote_listing = camera_bridge.list_remote_media()
                except Exception as exc:
                    remote_listing = {"ok": False, "error": str(exc)}

                if isinstance(remote_listing, dict) and isinstance(remote_listing.get("files"), list):
                    files = remote_listing["files"]
                    if not latest_media_url and files:
                        latest_media_url = files[0].get("url", "")
                        latest_media_file = files[0].get("name", "")

            self._send_json({
                "ok": True,
                "device_id": device_id,
                "model": cam.get("model", ""),
                "lan_ip": lan_ip,
                "http_media_port": http_media_port,
                "media_base_url": f"http://{lan_ip}:{http_media_port}/DJI_001/" if lan_ip else "",
                "latest_media_file": latest_media_file,
                "latest_media_url": latest_media_url,
                "media_http_verified": bool(verification.get("media_http_verified")),
                "dcim_root": "/mnt/media_rw/emulated/DCIM/DJI_001",
                "files": files,
                "remote_listing": remote_listing,
            })
            return

        if path == "/api/records/compare":
            bean_q = (qs.get("bean") or [""])[0]
            method_q = (qs.get("brew_method") or qs.get("method") or [""])[0]
            left_id = (qs.get("left_id") or [""])[0]
            right_id = (qs.get("right_id") or [""])[0]
            if not left_id and not right_id and qs.get("record_ids"):
                parts = [p.strip() for p in qs["record_ids"][0].split(",") if p.strip()]
                if len(parts) >= 2:
                    left_id, right_id = parts[0], parts[1]
            records = [r.to_dict() for r in store.list_records()]
            comparison = build_shot_comparison(
                records=records,
                bean=bean_q,
                brew_method=method_q,
                left_id=left_id,
                right_id=right_id,
            )
            self._send_json(comparison)
            return

        if path == "/api/state":
            records = [r.to_dict() for r in store.list_records()]
            cam_state = camera_bridge.load_state()
            cam_state["sta_network"].pop("password", None)
            cam_state.pop("auto_recovery", None)
            with open(camera_bridge.script_export_path, "r", encoding="utf-8") as f:
                agent_script = f.read()
            self._send_json({
                "ok": True,
                "records": records,
                "voice_session": voice_manager.get_status(),
                "camera_sta": cam_state,
                "usb_status": camera_bridge.scan_usb_and_serial_devices(),
                "bean_library": bean_manager.load_all(),
                "on_camera_script": agent_script,
                "notifications": notifier.get_history(),
                "notification_config": redact_notification_config(notifier.load_config()),
                "module_registry": global_registry.summary(),
                "context_snapshot": memory_manager.build_current_snapshot(),
            })
            return

        if path == "/api/camera/usb_probe":
            usb_scan = camera_bridge.scan_usb_and_serial_devices()
            auto_prov = camera_bridge.auto_provision_if_usb_connected()
            self._send_json({"ok": True, **usb_scan, "auto_provision": auto_prov})
            return

        if path == "/api/context/snapshot":
            snap = memory_manager.refresh_snapshot()
            self._send_json({"ok": True, "snapshot": snap, "registry": global_registry.summary()})
            return

        if path == "/api/media/keyframe":
            rel_or_abs = (qs.get("path") or [""])[0].strip()
            target = _resolve_confined_file(rel_or_abs, vision_engine.data_dir, ALLOWED_KEYFRAME_EXTENSIONS)
            if not target:
                self._send_json({"ok": False, "error": "Keyframe image not found"}, status=404)
                return
            mime = guess_media_mime(target)
            if not mime.startswith("image/"):
                mime = "image/jpeg"
            with open(target, "rb") as img_f:
                raw_img = img_f.read()
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(raw_img)))
            self.send_header("Cache-Control", "private, max-age=3600")
            self.end_headers()
            self.wfile.write(raw_img)
            return

        if path == "/api/media/file":
            rel_or_abs = (qs.get("path") or [""])[0].strip()
            target = _resolve_confined_file(rel_or_abs, store.data_dir, ALLOWED_MEDIA_EXTENSIONS)
            if not target:
                self._send_json({"ok": False, "error": "Media file not found"}, status=404)
                return
            file_size = os.path.getsize(target)
            mime = guess_media_mime(target)
            range_hdr = self.headers.get("Range")
            start, end = 0, max(0, file_size - 1)
            status_code = 200
            if range_hdr and range_hdr.startswith("bytes="):
                m = re.match(r"bytes=(\d*)-(\d*)", range_hdr.strip())
                if m:
                    s_str, e_str = m.group(1), m.group(2)
                    if s_str:
                        start = int(s_str)
                        end = int(e_str) if e_str else file_size - 1
                    elif e_str:
                        suffix = int(e_str)
                        start = max(0, file_size - suffix)
                        end = file_size - 1
                    end = min(end, file_size - 1)
                    if start > end or start >= file_size:
                        self.send_response(416)
                        self.send_header("Content-Range", f"bytes */{file_size}")
                        self.end_headers()
                        return
                    status_code = 206
            length = max(0, end - start + 1) if file_size > 0 else 0
            self.send_response(status_code)
            self.send_header("Content-Type", mime)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if status_code == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.send_header("Cache-Control", "private, max-age=3600")
            self.end_headers()
            with open(target, "rb") as media_f:
                media_f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = media_f.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            return

        if path == "/api/camera/script":
            with open(camera_bridge.script_export_path, "r", encoding="utf-8") as f:
                script_content = f.read()
            raw = script_content.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return

        if path.startswith("/api/"):
            self._send_json({"ok": False, "error": f"Unknown endpoint {path}"}, status=404)
            return

        segments = [seg for seg in path.split("/") if seg]
        if any(seg in (".", "..") or seg.startswith(".") for seg in segments):
            self.send_error(404, "File not found")
            return

        return super().do_GET()

    def do_POST(self) -> None:
        if not _is_trusted_host_header(self.headers.get("Host", "")):
            self._send_json({"ok": False, "error": "Untrusted Host header"}, status=403)
            return
        raw_origin = (self.headers.get("Origin") or "").strip()
        if raw_origin and not _allowed_cors_origin(raw_origin):
            self._send_json({"ok": False, "error": "Origin not allowed"}, status=403)
            return
        parsed = urlparse(self.path)
        path = parsed.path
        if path in ("/api/ingest/upload", "/api/recognize/media") and "multipart/form-data" in (self.headers.get("Content-Type") or "").lower():
            try:
                content_length = int(self.headers.get("Content-Length", "0"))
                upload_dir = os.path.join(store.data_dir, "uploads")
                fields, saved_file = parse_multipart_upload(
                    self.rfile,
                    self.headers.get("Content-Type", ""),
                    content_length,
                    upload_dir,
                )
            except ValueError as exc:
                self._send_json({"ok": False, "error": str(exc)}, status=400)
                return

            if saved_file:
                media_path = saved_file["path"]
            else:
                ok_mp, validated_mp, mp_err = _validate_client_media_reference(fields.get("media_path"), store.data_dir)
                if not ok_mp:
                    self._send_json({"ok": False, "error": mp_err}, status=403)
                    return
                media_path = validated_mp

            rel_media = os.path.relpath(media_path, store.data_dir) if (media_path and os.path.isfile(media_path) and os.path.realpath(media_path).startswith(os.path.realpath(store.data_dir) + os.sep)) else ""
            if rel_media:
                media_url = f"/api/media/file?path={quote(rel_media)}"
            else:
                ok_mu, validated_mu, mu_err = _validate_client_media_reference(fields.get("media_url"), store.data_dir)
                if not ok_mu:
                    self._send_json({"ok": False, "error": mu_err}, status=403)
                    return
                media_url = validated_mu
            source_type = _sanitize_source_device(fields.get("source_type"), "web_upload")
            source_device = _sanitize_source_device(fields.get("source_device"), "")
            record_intent = (fields.get("record_intent") or "auto").strip()[:32] or "auto"
            transcript = (fields.get("transcript") or "").strip()[:20000]
            mode = (fields.get("mode") or ("recognize_only" if path == "/api/recognize/media" else "ingest")).strip().lower()

            if not media_path and not media_url and not transcript:
                self._send_json({"ok": False, "error": "请上传视频/音频文件，或输入语音转写/文字描述"}, status=400)
                return

            pipeline = CoffeeIngestionPipeline(store, vision_engine, bean_manager, notifier, compactor)
            if mode == "recognize_only":
                rec_out = pipeline.recognize_media(
                    media_path=media_path or media_url,
                    spoken_transcript=transcript,
                    source_device=source_device or source_type,
                )
                self._send_json({
                    **rec_out,
                    "uploaded_file": saved_file,
                    "media_url": media_url,
                    "source_type": source_type,
                    "source_device": source_device,
                })
                return

            res = pipeline.ingest_media(
                media_path=media_path,
                media_url=media_url,
                transcript=transcript,
                source_device=source_device,
                source_type=source_type,
                record_intent=record_intent,
            )
            self._send_json({**res, "uploaded_file": saved_file, "media_url": media_url})
            return

        if path == "/api/camera/voice_chunk":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= VOICE_CHUNK_MAX_BODY:
                    raise ValueError("Invalid voice chunk body length")
                chunk_body = self._read_json_body()
                touch_fn = getattr(camera_bridge, "touch_camera_activity", None)
                if callable(touch_fn) and isinstance(chunk_body, dict):
                    touch_fn(chunk_body.get("device_id"), self.client_address[0])
                result = _camera_voice_chunk(chunk_body)
            except _RequestBodyError as exc:
                self._send_json({"ok": False, "error": str(exc)}, status=exc.status)
                return
            except (ValueError, UnicodeError) as exc:
                self._send_json({"ok": False, "error": str(exc)}, status=400)
                return
            self._send_json(result)
            return

        try:
            body = self._read_json_body()
        except _RequestBodyError as exc:
            self._send_json({"ok": False, "error": str(exc)}, status=exc.status)
            return

        if path == "/api/ingest/process":
            ok_mp, media_path, mp_err = _validate_client_media_reference(
                body.get("media_path") or body.get("video_path"), store.data_dir
            )
            if not ok_mp:
                self._send_json({"ok": False, "error": mp_err}, status=403)
                return
            ok_mu, media_url, mu_err = _validate_client_media_reference(body.get("media_url"), store.data_dir)
            if not ok_mu:
                self._send_json({"ok": False, "error": mu_err}, status=403)
                return
            transcript = str(body.get("transcript") or "").strip()[:20000]
            default_src_type = "manual_text" if not (media_path or media_url) else "web_upload"
            source_type = _sanitize_source_device(body.get("source_type"), default_src_type)
            source_device = _sanitize_source_device(body.get("source_device"), "")
            record_intent = str(body.get("record_intent") or "auto").strip()[:32] or "auto"
            hint_overrides = body.get("hint_overrides") or body.get("visual_hints")
            if not media_path and not media_url and not transcript:
                self._send_json({"ok": False, "error": "需要提供 media_path、media_url 或 transcript 中至少一项"}, status=400)
                return
            if media_path and not media_url and os.path.isfile(media_path):
                real_base = os.path.realpath(store.data_dir)
                real_media = os.path.realpath(media_path)
                if real_media.startswith(real_base + os.sep):
                    media_url = f"/api/media/file?path={quote(os.path.relpath(real_media, real_base))}"
            pipeline = CoffeeIngestionPipeline(store, vision_engine, bean_manager, notifier, compactor)
            res = pipeline.ingest_media(
                media_path=media_path,
                media_url=media_url,
                transcript=transcript,
                source_device=source_device,
                source_type=source_type,
                record_intent=record_intent,
                hint_overrides=hint_overrides,
                save=bool(body.get("save", True)),
                notify=bool(body.get("notify", True)),
            )
            self._send_json(res)
            return

        if path == "/api/recognize/media":
            ok_mp, media_path, mp_err = _validate_client_media_reference(
                body.get("media_path") or body.get("video_path"), store.data_dir
            )
            if not ok_mp:
                self._send_json({"ok": False, "error": mp_err}, status=403)
                return
            transcript = str(body.get("transcript") or "").strip()[:20000]
            source_device = _sanitize_source_device(body.get("source_device"), "通用录制设备")
            hint_overrides = body.get("hint_overrides") or body.get("visual_hints")
            if not media_path and not transcript:
                self._send_json({"ok": False, "error": "请提供 media_path 或 transcript"}, status=400)
                return
            pipeline = CoffeeIngestionPipeline(store, vision_engine, bean_manager, notifier, compactor)
            res = pipeline.recognize_media(
                media_path=media_path,
                spoken_transcript=transcript,
                source_device=source_device,
                hint_overrides=hint_overrides,
            )
            self._send_json(res)
            return

        if path == "/api/reports/generate":
            transcript = str(body.get("transcript") or "").strip()[:20000]
            visual_fields = body.get("visual_fields") or {}
            if not transcript and not visual_fields:
                self._send_json({"ok": False, "error": "请提供 transcript 或 visual_fields 以生成报告"}, status=400)
                return
            ok_vp, safe_video_path, vp_err = _validate_client_media_reference(
                body.get("media_path") or body.get("video_path"),
                store.data_dir,
                allow_synthetic_camera_path=True,
            )
            if not ok_vp:
                self._send_json({"ok": False, "error": vp_err}, status=403)
                return
            ok_mu, safe_media_url, mu_err = _validate_client_media_reference(body.get("media_url"), store.data_dir)
            if not ok_mu:
                self._send_json({"ok": False, "error": mu_err}, status=403)
                return
            safe_frames = _sanitize_client_keyframes(
                body.get("frame_observations") or body.get("keyframes") or [],
                store.data_dir,
            )
            pipeline = CoffeeIngestionPipeline(store, vision_engine, bean_manager, notifier, compactor)
            res = pipeline.generate_report(
                transcript=transcript,
                source_device=_sanitize_source_device(body.get("source_device"), ""),
                source_type=_sanitize_source_device(body.get("source_type"), "web_upload"),
                media_kind=body.get("media_kind"),
                video_path=safe_video_path,
                media_url=safe_media_url,
                visual_fields=visual_fields if isinstance(visual_fields, dict) else {},
                frame_observations=safe_frames,
                record_intent=str(body.get("record_intent") or "auto").strip()[:32] or "auto",
                save=bool(body.get("save", True)),
                notify=bool(body.get("notify", True)),
            )
            res.pop("record_obj", None)
            res.pop("compacted_obj", None)
            self._send_json(res)
            return

        if path == "/api/camera/auto_recover":
            accepted = camera_bridge.request_auto_recovery()
            self._send_json({"ok": accepted, "auto_recovery": camera_bridge.recovery_status()},
                            status=202 if accepted else 503)
            return

        if path == "/api/camera/heartbeat":
            result = camera_bridge.record_heartbeat(body, self.client_address[0])
            if result.get("sta_verified"):
                result["server_epoch"] = int(time.time())
            self._send_json(result, status=200 if result["ok"] else 400)
            return

        if path == "/api/voice/wake":
            cam_id = body.get("camera_id", "pocket4p")
            phrase = body.get("phrase", "我要开始制作咖啡。")
            session = voice_manager.start_session(camera_id=cam_id, initial_phrase=phrase)
            self._send_json({"ok": True, "voice_session": session})
            return

        if path == "/api/voice/utterance":
            text = body.get("text", "")
            result = voice_manager.append_utterance(text)
            self._send_json({"ok": True, **result})
            return

        if path == "/api/voice/stop":
            transcript = body.get("transcript")
            cam_id = body.get("camera_id")
            ok_mu, media_url, mu_err = _validate_client_media_reference(body.get("media_url"), store.data_dir)
            if not ok_mu:
                self._send_json({"ok": False, "error": mu_err}, status=403)
                return
            ok_vp, video_path, vp_err = _validate_client_media_reference(
                body.get("video_path") or body.get("file_path"),
                store.data_dir,
                allow_synthetic_camera_path=True,
            )
            if not ok_vp:
                self._send_json({"ok": False, "error": vp_err}, status=403)
                return
            hint_overrides = body.get("hint_overrides") or body.get("visual_hints")
            reason = str(body.get("reason") or "检测到咖啡制作结束，自动停止录制并生成报告")[:200]
            result = voice_manager.stop_and_process(
                reason=reason,
                override_transcript=transcript,
                camera_id=cam_id,
                media_url=media_url,
                video_path=video_path,
                hint_overrides=hint_overrides,
            )
            self._send_json({"ok": True, **result})
            return

        if path == "/api/records/supplement":
            record_id = str(body.get("record_id") or "")
            rec = store.get_record(record_id)
            if not rec:
                self._send_json({"ok": False, "error": "未找到对应的咖啡记录"}, status=404)
                return

            # Support both structured field updates and voice/text supplement
            supplement_text = str(body.get("supplement_text") or "").strip()[:4000]
            if supplement_text:
                rec.transcript = (rec.transcript + " 补充说明：" + supplement_text).strip()
                parsed_supp = extract_parameters_from_transcript(supplement_text, rec.camera_device)
                for field_name in [
                    "bean_name", "bean_roast", "bean_weight_g", "grind_setting",
                    "grinder_type", "grinder_model", "brew_method", "yield_g",
                    "extraction_time_s", "pressure_bar", "water_temp_c",
                ]:
                    new_val = getattr(parsed_supp, field_name, None)
                    if new_val is not None:
                        setattr(rec, field_name, new_val)

            updates = body.get("updates") or {}
            if not isinstance(updates, dict):
                self._send_json({"ok": False, "error": "updates must be a JSON object"}, status=400)
                return
            for k, v in updates.items():
                if v is None or v == "":
                    continue
                if k in SUPPLEMENT_FLOAT_FIELDS:
                    try:
                        fval = float(v)
                        if math.isfinite(fval) and 0 < fval <= 100000:
                            setattr(rec, k, fval)
                    except (TypeError, ValueError):
                        pass
                elif k in SUPPLEMENT_STRING_FIELDS:
                    setattr(rec, k, str(v).strip()[:200])

            rec.compute_derived_metrics()
            enrich_barista_analysis(rec)
            store.save_record(rec)
            notif = notifier.notify_brew_record(rec)
            self._send_json({
                "ok": True,
                "record": rec.to_dict(),
                "notification": notif,
            })
            return

        if path == "/api/camera/provision_sta":
            res = camera_bridge.provision_sta_mode(
                device_id=body.get("device_id", "pocket4p"),
                ssid=body.get("ssid", "Home_Coffee_LAN"),
                password=body.get("password", ""),
                lan_ip=body.get("lan_ip", "192.168.5.108"),
                mac_server_ip=body.get("mac_server_ip", "192.168.5.84"),
            )
            self._send_json(res, status=400 if res.get("invalid_input") else 200)
            return

        if path == "/api/camera/exec":
            if not _is_loopback_client(self.client_address[0]):
                self._send_json(
                    {"ok": False, "error": "ADB diagnostic commands are restricted to local loopback"},
                    status=403,
                )
                return
            shell_cmd = body.get("cmd", "iw dev wlan0 info && ps")
            if not _is_allowed_diagnostic_shell_cmd(shell_cmd):
                self._send_json(
                    {"ok": False, "error": "Command rejected: only read-only diagnostic commands are permitted over HTTP"},
                    status=403,
                )
                return
            res = camera_bridge.execute_internal_command(
                device_id=body.get("device_id", "pocket4p"),
                shell_cmd=shell_cmd,
            )
            self._send_json(res)
            return

        if path == "/api/camera/shutter":
            res = camera_bridge.trigger_lan_recording(
                device_id=body.get("device_id", "pocket4p"),
                action=body.get("action", "start"),
            )
            self._send_json(res)
            return

        if path == "/api/camera/gimbal":
            device_id = body.get("device_id", "pocket4p")
            preset = body.get("preset", "reset_center")
            pitch_deg = body.get("pitch_deg")
            yaw_deg = body.get("yaw_deg")
            move_fn = getattr(camera_bridge, "move_gimbal_preset", None)
            if not callable(move_fn):
                self._send_json(
                    {
                        "ok": False,
                        "error": "Camera bridge does not support move_gimbal_preset",
                        "device_id": device_id,
                        "preset": preset,
                    },
                    status=501,
                )
                return
            try:
                res = move_fn(
                    device_id=device_id,
                    preset=preset,
                    pitch_deg=pitch_deg,
                    yaw_deg=yaw_deg,
                )
            except TypeError:
                res = move_fn(device_id, preset)

            err_msg = str(res.get("error") or "")
            is_client_error = any(
                token in err_msg
                for token in (
                    "Unknown gimbal preset",
                    "outside the DUML",
                    "finite numbers",
                )
            ) or (err_msg.startswith("Camera ") and err_msg.endswith(" not found"))
            self._send_json(res, status=400 if is_client_error else 200)
            return

        if path == "/api/camera/pull_media":
            device_id = body.get("device_id", "pocket4p")
            max_bytes = body.get("max_bytes")
            extract_keyframes = body.get("extract_keyframes", True)
            pull_fn = getattr(camera_bridge, "pull_latest_media", None)
            if not callable(pull_fn):
                self._send_json(
                    {
                        "ok": False,
                        "error": "Camera bridge does not support pull_latest_media",
                        "device_id": device_id,
                    },
                    status=501,
                )
                return
            pull_res = pull_fn(
                device_id=device_id, max_bytes=max_bytes, filename=body.get("filename")
            )

            if pull_res.get("ok") and pull_res.get("local_path") and extract_keyframes:
                video_meta = vision_engine.extract_video_metadata_and_frames(pull_res["local_path"])
                pull_res = {
                    **pull_res,
                    "video_metadata": video_meta,
                    "keyframes": video_meta.get("keyframes", []),
                }
            self._send_json(pull_res, status=400 if "max_bytes" in str(pull_res.get("error", "")) else 200)
            return

        if path == "/api/camera/webhook":
            # Triggered automatically by /data/pocket-coffee/pocket_sta_agent.sh inside Pocket 3 / Pocket 4 Pro
            camera_id = body.get("device_id") or (
                "pocket3" if "Pocket 3" in str(body.get("camera", "")) else None
            )
            touch_fn = getattr(camera_bridge, "touch_camera_activity", None)
            if callable(touch_fn):
                touch_fn(camera_id or "pocket4p", self.client_address[0])
            ok_fp, file_path, fp_err = _validate_client_media_reference(
                body.get("file_path") or body.get("video_path"),
                store.data_dir,
                allow_synthetic_camera_path=True,
            )
            if not ok_fp:
                self._send_json({"ok": False, "error": fp_err}, status=403)
                return
            ok_mu, media_url, mu_err = _validate_client_media_reference(body.get("media_url"), store.data_dir)
            if not ok_mu:
                self._send_json({"ok": False, "error": mu_err}, status=403)
                return
            transcript = body.get("transcript")
            hint_overrides = body.get("hint_overrides") or body.get("visual_hints")
            clip_name = os.path.basename(
                file_path or media_url or "/mnt/media_rw/emulated/DCIM/DJI_001/DJI_AUTO.MP4"
            )
            res = voice_manager.stop_and_process(
                reason=f"相机内部守护进程推送新视频 ({clip_name})",
                override_transcript=transcript,
                camera_id=camera_id,
                media_url=media_url,
                video_path=file_path,
                hint_overrides=hint_overrides,
                media_finalized=True,
            )
            self._send_json({"ok": True, "webhook_processed": True, **res})
            return

        if path == "/api/beans/scan_label":
            label_text = str(body.get("text") or body.get("label_text") or "").strip()
            if not label_text:
                self._send_json({"ok": False, "error": "豆袋标签或描述文本不能为空"}, status=400)
                return
            bean_entry = bean_manager.parse_bean_label_text(label_text)
            self._send_json({"ok": True, "bean": bean_entry, "bean_library": bean_manager.load_all()})
            return

        if path == "/api/beans/save":
            if not isinstance(body, dict):
                self._send_json({"ok": False, "error": "Expected JSON object"}, status=400)
                return
            try:
                bean_entry = bean_manager.add_or_update_bean(body)
            except ValueError as exc:
                self._send_json({"ok": False, "error": str(exc)}, status=400)
                return
            self._send_json({"ok": True, "bean": bean_entry, "bean_library": bean_manager.load_all()})
            return

        if path == "/api/equipment/save":
            lib_data = bean_manager.load_all()
            current_eq = dict(lib_data.get("equipment") or {})
            for k in ALLOWED_EQUIPMENT_FIELDS:
                if k not in body:
                    continue
                if k == "default_water_temp_c":
                    try:
                        temp = float(body[k])
                        if math.isfinite(temp) and 0 < temp <= 110:
                            current_eq[k] = temp
                    except (TypeError, ValueError):
                        pass
                elif k == "auto_fill_default_grinder":
                    current_eq[k] = bool(body[k])
                else:
                    current_eq[k] = str(body[k] or "").strip()[:200]
            lib_data["equipment"] = current_eq
            bean_manager.save_all(lib_data)
            self._send_json({"ok": True, "equipment": lib_data["equipment"]})
            return

        if path == "/api/records/feedback":
            record_id = str(body.get("record_id") or "")
            rec = store.get_record(record_id)
            if not rec:
                self._send_json({"ok": False, "error": "Record not found"}, status=404)
                return
            try:
                rating = max(1, min(5, int(body.get("rating", 5))))
            except (TypeError, ValueError):
                self._send_json({"ok": False, "error": "rating must be an integer between 1 and 5"}, status=400)
                return
            taste_tag = str(body.get("taste_tag") or "balanced_sweet").strip()
            if taste_tag not in ALLOWED_TASTE_TAGS:
                self._send_json({"ok": False, "error": "Invalid taste_tag"}, status=400)
                return
            user_note = str(body.get("user_note") or "")[:500]
            fb = bean_manager.apply_taste_feedback(rec.to_dict(), rating, taste_tag, user_note)
            # Prepend the subjective calibration advice directly into the record's suggestions
            rec.suggestions.insert(0, fb["calibration_advice"])
            store.save_record(rec)
            self._send_json({"ok": True, "feedback": fb, "record": rec.to_dict()})
            return

        if path == "/api/notifications/config":
            cfg = notifier.load_config()
            candidate = dict(cfg)
            for k in ["mobile_base_url", "wecom_webhook_url", "serverchan_sendkey", "bark_url", "feishu_webhook_url", "enable_macos_banner"]:
                if k not in body:
                    continue
                if k == "enable_macos_banner":
                    candidate[k] = bool(body[k])
                elif k in SECRET_NOTIFICATION_KEYS and body[k] == REDACTED_SECRET_PLACEHOLDER:
                    continue
                else:
                    candidate[k] = str(body[k] or "").strip()
            validation_err = validate_notification_config(candidate)
            if validation_err:
                self._send_json({"ok": False, "error": validation_err}, status=400)
                return
            notifier.save_config(candidate)
            self._send_json({"ok": True, "config": redact_notification_config(candidate)})
            return

        self._send_json({"ok": False, "error": f"Unknown endpoint {path}"}, status=404)


def run_server(host: Optional[str] = None, port: int = 8788) -> None:
    bind_host = host if host is not None else os.environ.get("HOST", "127.0.0.1")
    server = ThreadingHTTPServer((bind_host, port), CoffeeRequestHandler)
    print(f"☕️ Pocket Coffee Log Server listening on http://{bind_host}:{port}")
    camera_bridge.start_auto_recovery()
    try:
        server.serve_forever()
    finally:
        camera_bridge.stop_auto_recovery()
        server.server_close()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8788"))
    run_server(port=port)
