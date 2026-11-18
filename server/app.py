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
import tempfile
import time
import wave
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qs, urlparse

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.analyzer import enrich_barista_analysis, extract_parameters_from_transcript
from core.bean_equipment_store import BeanAndEquipmentManager
from core.camera_sta_bridge import CameraInternalBridge
from core.context_engine import ProjectMemoryManager, SessionContextCompactor
from core.multimodal_vision import MultimodalVisionEngine
from core.notifier import NotificationManager
from core.registry import global_event_bus, global_registry
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager


DATA_DIR = os.path.join(PROJECT_ROOT, "data")
STATIC_DIR = os.path.join(PROJECT_ROOT, "static")

store = CoffeeStore(DATA_DIR)
camera_bridge = CameraInternalBridge(DATA_DIR)
notifier = NotificationManager(DATA_DIR)
bean_manager = BeanAndEquipmentManager(DATA_DIR)
vision_engine = MultimodalVisionEngine(DATA_DIR)
voice_manager = VoiceWakeupSessionManager(store, camera_bridge, notifier)
memory_manager = ProjectMemoryManager(PROJECT_ROOT)
compactor = SessionContextCompactor()

# Register core modules in global ModuleRegistry
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
    peak = max(max(samples), -min(samples)) if samples else 0
    if peak >= 160:
        # Check short windows so a brief word is not averaged into the entire clip.
        speech_energy = any(
            sum(sample * sample for sample in window) >= len(window) * 50**2
            for window in (samples[i:i + 800] for i in range(0, len(samples), 800))
        )
        if speech_energy:
            with tempfile.NamedTemporaryFile(suffix=".wav") as audio:
                if peak < 3000:
                    dc_offset = sum(samples) / len(samples)
                    centered_peak = max(max(samples) - dc_offset, dc_offset - min(samples))
                    if not centered_peak:
                        return {"ok": True, "transcript": "", "command": "none", "action_token": "ACTION:NONE"}
                    gain = min(12.0, 8000 / centered_peak)
                    normalized = array("h", (round((sample - dc_offset) * gain) for sample in samples))
                    if sys.byteorder != "little":
                        normalized.byteswap()
                    with wave.open(audio, "wb") as wav:
                        wav.setparams((1, 2, 16000, 0, "NONE", ""))
                        wav.writeframes(normalized.tobytes())
                else:
                    audio.write(raw)
                audio.flush()
                transcript = vision_engine.extract_audio_and_transcribe(audio.name).strip()
            if transcript:
                command = voice_manager.handle_camera_transcript(device_id, transcript, recording)
                print(f"[CameraMic] {device_id}: transcript={transcript!r} -> command={command}", flush=True)
    return {"ok": True, "transcript": transcript, "command": command, "action_token": f"ACTION:{command.upper()}"}


class CoffeeRequestHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def log_message(self, format: str, *args) -> None:
        # Quiet standard stdout logging
        pass

    def _send_json(self, payload: Dict[str, Any], status: int = 200) -> None:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(raw)

    def _read_json_body(self) -> Dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        raw = self.rfile.read(length).decode("utf-8")
        try:
            return json.loads(raw)
        except Exception:
            return {}

    def do_OPTIONS(self) -> None:
        self._send_json({"ok": True})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

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
                "notification_config": notifier.load_config(),
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
            base_dir = os.path.realpath(vision_engine.data_dir)
            target = ""
            if rel_or_abs:
                cand = os.path.realpath(rel_or_abs)
                if not (cand.startswith(base_dir + os.sep) and os.path.isfile(cand)):
                    cand = os.path.realpath(os.path.join(base_dir, rel_or_abs.lstrip("/")))
                target = cand
            if not target or not (target.startswith(base_dir + os.sep)) or not os.path.isfile(target):
                self._send_json({"ok": False, "error": "Keyframe image not found"}, status=404)
                return
            with open(target, "rb") as img_f:
                raw_img = img_f.read()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(raw_img)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            self.wfile.write(raw_img)
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

        return super().do_GET()

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/camera/voice_chunk":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= VOICE_CHUNK_MAX_BODY:
                    raise ValueError("Invalid voice chunk body length")
                result = _camera_voice_chunk(self._read_json_body())
            except (ValueError, UnicodeError) as exc:
                self._send_json({"ok": False, "error": str(exc)}, status=400)
                return
            self._send_json(result)
            return
        body = self._read_json_body()

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
            media_url = body.get("media_url")
            video_path = body.get("video_path") or body.get("file_path")
            hint_overrides = body.get("hint_overrides") or body.get("visual_hints")
            reason = body.get("reason", "检测到咖啡制作结束，自动停止录制并生成报告")
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
            record_id = body.get("record_id", "")
            rec = store.get_record(record_id)
            if not rec:
                self._send_json({"ok": False, "error": "未找到对应的咖啡记录"}, status=404)
                return

            # Support both structured field updates and voice/text supplement
            supplement_text = body.get("supplement_text", "").strip()
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

            updates = body.get("updates", {})
            float_fields = {"bean_weight_g", "yield_g", "extraction_time_s", "pressure_bar", "water_temp_c"}
            for k, v in updates.items():
                if v is None or v == "":
                    continue
                if k in float_fields:
                    try:
                        setattr(rec, k, float(v))
                    except ValueError:
                        pass
                elif hasattr(rec, k):
                    setattr(rec, k, str(v).strip())

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
            self._send_json(res)
            return

        if path == "/api/camera/exec":
            res = camera_bridge.execute_internal_command(
                device_id=body.get("device_id", "pocket4p"),
                shell_cmd=body.get("cmd", "iw dev wlan0 info && ps"),
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
            file_path = body.get("file_path") or body.get("video_path")
            media_url = body.get("media_url")
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
            label_text = (body.get("text") or body.get("label_text") or "").strip()
            if not label_text:
                self._send_json({"ok": False, "error": "豆袋标签或描述文本不能为空"}, status=400)
                return
            bean_entry = bean_manager.parse_bean_label_text(label_text)
            self._send_json({"ok": True, "bean": bean_entry, "bean_library": bean_manager.load_all()})
            return

        if path == "/api/beans/save":
            bean_entry = bean_manager.add_or_update_bean(body)
            self._send_json({"ok": True, "bean": bean_entry, "bean_library": bean_manager.load_all()})
            return

        if path == "/api/equipment/save":
            lib_data = bean_manager.load_all()
            lib_data["equipment"] = {**lib_data.get("equipment", {}), **body}
            bean_manager.save_all(lib_data)
            self._send_json({"ok": True, "equipment": lib_data["equipment"]})
            return

        if path == "/api/records/feedback":
            record_id = body.get("record_id", "")
            rec = store.get_record(record_id)
            if not rec:
                self._send_json({"ok": False, "error": "Record not found"}, status=404)
                return
            rating = int(body.get("rating", 5))
            taste_tag = body.get("taste_tag", "balanced_sweet")
            user_note = body.get("user_note", "")
            fb = bean_manager.apply_taste_feedback(rec.to_dict(), rating, taste_tag, user_note)
            # Prepend the subjective calibration advice directly into the record's suggestions
            rec.suggestions.insert(0, fb["calibration_advice"])
            store.save_record(rec)
            self._send_json({"ok": True, "feedback": fb, "record": rec.to_dict()})
            return

        if path == "/api/notifications/config":
            cfg = notifier.load_config()
            for k in ["mobile_base_url", "wecom_webhook_url", "serverchan_sendkey", "bark_url", "feishu_webhook_url", "enable_macos_banner"]:
                if k in body:
                    cfg[k] = body[k]
            notifier.save_config(cfg)
            self._send_json({"ok": True, "config": cfg})
            return

        self._send_json({"ok": False, "error": f"Unknown endpoint {path}"}, status=404)


def run_server(host: str = "0.0.0.0", port: int = 8788) -> None:
    server = ThreadingHTTPServer((host, port), CoffeeRequestHandler)
    print(f"☕️ Pocket Coffee Log Server listening on http://{host}:{port}")
    camera_bridge.start_auto_recovery()
    try:
        server.serve_forever()
    finally:
        camera_bridge.stop_auto_recovery()
        server.server_close()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8788"))
    run_server(port=port)
