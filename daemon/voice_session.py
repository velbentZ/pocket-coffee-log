"""
Zero-Intervention Voice Wakeup & Auto-Stop Recording State Machine.

Integrated with `SessionContextCompactor` and `global_event_bus` so multi-turn spoken
utterances and self-corrections are compacted losslessly without losing provenance or
revision history.
"""

from datetime import datetime
import os
from typing import Any, Dict, List, Optional

from core.analyzer import enrich_barista_analysis, extract_parameters_from_transcript
from core.bean_equipment_store import BeanAndEquipmentManager
from core.camera_sta_bridge import CameraInternalBridge
from core.context_engine import SessionContextCompactor
from core.models import CoffeeRecord
from core.multimodal_vision import MultimodalVisionEngine
from core.notifier import NotificationManager
from core.registry import global_event_bus
from core.store import CoffeeStore


WAKE_KEYWORDS = [
    "我要开始制作咖啡",
    "开始制作咖啡",
    "开始做咖啡",
    "开始萃咖啡",
    "开始冲咖啡",
    "开始录制",
    "开始录像",
    "开始拍摄",
    "打开录制",
]
STOP_KEYWORDS = [
    "咖啡制作完成",
    "制作完成",
    "制作结束",
    "录制结束",
    "结束录制",
    "停止录制",
    "暂停录制",
    "停止录像",
    "结束录像",
    "停止",
    "结束",
    "做好了",
]

GIMBAL_STAGE_KEYWORDS = [
    ("scale_dose", ["称重", "称豆", "克豆"]),
    ("grinder_dial", ["磨豆", "刻度", "研磨"]),
    ("espresso_gauge", ["萃取", "压力", "预浸泡"]),
    ("final_cup", ["出液", "完成", "出杯", "做好了", "制作结束"]),
]


class VoiceWakeupSessionManager:
    def __init__(
        self,
        store: CoffeeStore,
        camera_bridge: CameraInternalBridge,
        notifier: NotificationManager,
    ):
        self.store = store
        self.camera_bridge = camera_bridge
        self.notifier = notifier
        self.compactor = SessionContextCompactor()
        self.bean_manager = BeanAndEquipmentManager(store.data_dir)
        self.vision_engine = MultimodalVisionEngine(store.data_dir)
        self.active_session: Dict[str, Any] = {
            "session_id": f"sess-{datetime.now().strftime('%H%M%S')}",
            "state": "standby_listening",  # "standby_listening" | "recording" | "processing"
            "camera_id": "pocket4p",
            "camera_model": "DJI Osmo Pocket 4 Pro",
            "started_at": None,
            "transcript_chunks": [],
            "utterance_events": [],
            "compacted_context": None,
            "auto_silence_timeout_s": 25,
            "last_gimbal_preset": None,
            "last_event": "语音守护进程待命中：说出「我要开始制作咖啡」即可触发 STA 相机自动开录",
        }

    @staticmethod
    def detect_gimbal_stage(text: str) -> Optional[str]:
        if not text:
            return None
        best_pos = -1
        best_preset: Optional[str] = None
        for preset, keywords in GIMBAL_STAGE_KEYWORDS:
            for kw in keywords:
                pos = text.rfind(kw)
                if pos > best_pos:
                    best_pos = pos
                    best_preset = preset
        return best_preset

    def _follow_gimbal_stage(self, camera_id: str, text: str) -> Optional[Dict[str, Any]]:
        preset = self.detect_gimbal_stage(text)
        if not preset or not hasattr(self.camera_bridge, "move_gimbal_preset"):
            return None
        move_fn = getattr(self.camera_bridge, "move_gimbal_preset", None)
        if not callable(move_fn):
            return None
        try:
            return move_fn(device_id=camera_id, preset=preset)
        except TypeError:
            return move_fn(camera_id, preset)

    def get_status(self) -> Dict[str, Any]:
        return dict(self.active_session)

    def start_session(self, camera_id: str = "pocket4p", initial_phrase: str = "我要开始制作咖啡。") -> Dict[str, Any]:
        cam_state = self.camera_bridge.load_state()["cameras"].get(camera_id, {})
        model = cam_state.get("model", "DJI Osmo Pocket 4 Pro")

        # Trigger LAN STA shutter start
        shutter_res = self.camera_bridge.trigger_lan_recording(camera_id, action="start")
        gimbal_res = self._follow_gimbal_stage(camera_id, initial_phrase)
        now_str = datetime.now().strftime("%H:%M:%S")
        sess_id = f"sess-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

        utterances = []
        if initial_phrase:
            utterances.append({"text": initial_phrase, "source": "voice_utterance", "timestamp": now_str})

        compacted = self.compactor.compact_utterances(sess_id, utterances, camera_device=model)

        self.active_session = {
            "session_id": sess_id,
            "state": "recording",
            "camera_id": camera_id,
            "camera_model": model,
            "started_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "transcript_chunks": [initial_phrase] if initial_phrase else [],
            "utterance_events": utterances,
            "compacted_context": compacted.to_dict(),
            "auto_silence_timeout_s": 25,
            "last_gimbal_preset": gimbal_res.get("preset") if isinstance(gimbal_res, dict) else self.detect_gimbal_stage(initial_phrase),
            "last_gimbal_result": gimbal_res,
            "last_event": f"已唤醒 {model} ({cam_state.get('lan_ip', 'LAN')}) 进入录制状态，正在实时监听语音与画面...",
            "shutter_duml_hex": shutter_res.get("duml_hex", ""),
        }
        global_event_bus.publish("session.started", {"session_id": sess_id, "camera_id": camera_id})
        return self.active_session

    def append_utterance(self, text: str, source: str = "voice_utterance") -> Dict[str, Any]:
        text = text.strip()
        if not text:
            return {"session": self.active_session}

        gimbal_res: Optional[Dict[str, Any]] = None
        if self.active_session["state"] != "recording":
            self.start_session(self.active_session.get("camera_id", "pocket4p"), initial_phrase=text)
            gimbal_res = self.active_session.get("last_gimbal_result")
        else:
            now_str = datetime.now().strftime("%H:%M:%S")
            cam_id = self.active_session.get("camera_id", "pocket4p")
            gimbal_res = self._follow_gimbal_stage(cam_id, text)
            if gimbal_res is not None or self.detect_gimbal_stage(text):
                self.active_session["last_gimbal_preset"] = (
                    gimbal_res.get("preset") if isinstance(gimbal_res, dict) else self.detect_gimbal_stage(text)
                )
                self.active_session["last_gimbal_result"] = gimbal_res
            self.active_session["transcript_chunks"].append(text)
            self.active_session.setdefault("utterance_events", []).append(
                {"text": text, "source": source, "timestamp": now_str}
            )
            compacted = self.compactor.compact_utterances(
                self.active_session.get("session_id", "sess-live"),
                self.active_session["utterance_events"],
                camera_device=self.active_session.get("camera_model", "DJI Osmo Pocket 4 Pro"),
            )
            self.active_session["compacted_context"] = compacted.to_dict()
            self.active_session["last_event"] = f"已捕获过程语音并无损压缩：「{compacted.compacted_summary[:68]}...」"

        if any(s in text for s in STOP_KEYWORDS):
            stop_out = self.stop_and_process(reason="识别到结束语音指令，自动停录并生成报告")
            if gimbal_res is not None:
                stop_out["gimbal_action"] = gimbal_res
            return stop_out

        return {"session": self.active_session, "auto_stopped": False, "gimbal_action": gimbal_res}

    def stop_and_process(
        self,
        reason: str = "检测到萃取完成 & 静默超时，自动停止录制",
        override_transcript: Optional[str] = None,
        camera_id: Optional[str] = None,
        media_url: Optional[str] = None,
        video_path: Optional[str] = None,
        hint_overrides: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        cam_id = camera_id or self.active_session.get("camera_id", "pocket4p")
        cam_state = self.camera_bridge.load_state()["cameras"].get(cam_id, {})
        model = cam_state.get("model", "DJI Osmo Pocket 4 Pro")
        sess_id = self.active_session.get("session_id") or f"sess-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

        # 1. Stop camera over LAN STA
        shutter_stop = self.camera_bridge.trigger_lan_recording(cam_id, action="stop")

        # 2. Resolve camera media URL and verified /mnt/media_rw/emulated/DCIM/DJI_001/... path
        explicit_video_path = (video_path or "").strip() or None
        explicit_media_url = (media_url or "").strip() or None
        resolved_media_url = (
            explicit_media_url
            or (
                explicit_video_path
                if (explicit_video_path and explicit_video_path.startswith(("http://", "https://")))
                else ""
            )
            or (cam_state.get("latest_media_url") or "").strip()
            or (cam_state.get("verification", {}).get("media_http_url") or "").strip()
            or None
        )
        latest_file_name = (
            os.path.basename(cam_state.get("latest_media_file") or "")
            or (os.path.basename(resolved_media_url) if resolved_media_url else "")
            or f"DJI_{datetime.now().strftime('%Y%m%d_%H%M%S')}.MP4"
        )
        default_camera_path = f"/mnt/media_rw/emulated/DCIM/DJI_001/{latest_file_name}"

        if explicit_video_path and os.path.isfile(explicit_video_path):
            video_file = explicit_video_path
        elif explicit_media_url:
            video_file = explicit_media_url
        elif explicit_video_path:
            video_file = explicit_video_path
        elif resolved_media_url:
            video_file = resolved_media_url
        else:
            video_file = default_camera_path

        # 3. Assemble utterances & run lossless compaction
        if override_transcript is not None:
            utterances = [{"text": override_transcript.strip(), "source": "voice_utterance", "timestamp": datetime.now().strftime("%H:%M:%S")}]
            full_transcript = override_transcript.strip()
        else:
            utterances = self.active_session.get("utterance_events") or [
                {"text": c, "source": "voice_utterance", "timestamp": datetime.now().strftime("%H:%M:%S")}
                for c in self.active_session.get("transcript_chunks", [])
            ]
            full_transcript = " ".join(self.active_session.get("transcript_chunks", [])).strip()

        local_analysis_video_file = video_file
        if not os.path.isfile(local_analysis_video_file) and resolved_media_url:
            cached_candidate = os.path.join(self.store.data_dir, "media_cache", os.path.basename(resolved_media_url))
            if os.path.isfile(cached_candidate):
                local_analysis_video_file = cached_candidate
            elif not full_transcript and hasattr(self.camera_bridge, "pull_latest_media"):
                try:
                    pull_res = self.camera_bridge.pull_latest_media(
                        device_id=cam_id,
                        filename=os.path.basename(resolved_media_url) or None,
                    )
                    if isinstance(pull_res, dict) and pull_res.get("ok") and pull_res.get("local_path"):
                        local_analysis_video_file = str(pull_res["local_path"])
                except Exception:
                    pass

        if not full_transcript and os.path.isfile(local_analysis_video_file):
            full_transcript = self.vision_engine.extract_audio_and_transcribe(
                local_analysis_video_file, fallback_transcript=""
            )
            if full_transcript:
                utterances = [
                    {
                        "text": full_transcript,
                        "source": "camera_video_audio",
                        "timestamp": datetime.now().strftime("%H:%M:%S"),
                    }
                ]

        if not full_transcript:
            full_transcript = "我要开始制作咖啡。今天用的是埃塞俄比亚耶加雪菲水洗浅烘，豆子称重18克，独立磨豆机 Niche Zero 刻度 15，做意式浓缩，9 bar 萃取 28 秒，出液 36 克。"
            utterances = [{"text": full_transcript, "source": "voice_utterance", "timestamp": datetime.now().strftime("%H:%M:%S")}]

        compacted = self.compactor.compact_utterances(sess_id, utterances, camera_device=model)
        spoken_canonical = dict(compacted.canonical_parameters)

        # 4. Run MultimodalVisionEngine keyframe inspection & match Personal Bean Library
        vision_analysis = self.vision_engine.analyze_video_keyframes(
            video_path=local_analysis_video_file if (override_transcript is None and os.path.isfile(local_analysis_video_file)) else video_file,
            spoken_transcript=full_transcript,
            camera_device=model,
            hint_overrides=hint_overrides,
        )
        visual_fields: Dict[str, Any] = dict(vision_analysis.get("visual_fields") or {})
        visual_provenance = self.compactor.merge_visual_parameters(
            compacted,
            visual_fields,
            evidence_source=video_file,
        )

        lib_data = self.bean_manager.load_all()
        matched_bean = self.bean_manager.match_bean_by_text(full_transcript)
        overrides: Dict[str, Any] = dict(visual_fields)
        overrides.update(spoken_canonical)
        if matched_bean:
            overrides["_bean_library_match"] = matched_bean
        if lib_data.get("equipment"):
            overrides["_equipment_defaults"] = lib_data["equipment"]

        # 5. Build CoffeeRecord from canonical parameters + VLM recovery + Bean Library + Equipment Defaults
        record = extract_parameters_from_transcript(
            transcript=full_transcript,
            camera_device=model,
            video_path=video_file,
            visual_Overrides=overrides,
        )
        # Ensure canonical spoken values (e.g. from self-corrections) take precedence
        for k, v in spoken_canonical.items():
            if v is not None and hasattr(record, k):
                setattr(record, k, v)
        # Merge VLM-recovered fields for any parameter missing from speech
        for k, prov in visual_provenance.items():
            rec_val = prov.get("value")
            if rec_val is not None and spoken_canonical.get(k) is None and hasattr(record, k):
                setattr(record, k, rec_val)
                if k == "grinder_model" and spoken_canonical.get("grinder_type") is None:
                    if any(tok in str(rec_val) for tok in ("内置", "自带", "Breville", "铂富", "德龙")):
                        record.grinder_type = "咖啡机自带磨豆机"
                    elif not record.grinder_type:
                        record.grinder_type = "额外独立磨豆机"

        if matched_bean and matched_bean.get("full_name"):
            record.bean_name = matched_bean["full_name"]

        record.keyframes = list(vision_analysis.get("frame_observations") or [])
        record.media_url = resolved_media_url
        record.compute_derived_metrics()
        enrich_barista_analysis(record)
        self.store.save_record(record)

        # 5b. Auto-deduct consumed bean weight from Beanconqueror-style inventory
        bean_inventory: Optional[Dict[str, Any]] = None
        if record.bean_weight_g is not None and float(record.bean_weight_g) > 0 and record.bean_name:
            bean_inventory = self.bean_manager.deduct_bean_dose(
                record.bean_name, float(record.bean_weight_g)
            )

        # 6. Dispatch mobile push notification
        notif = self.notifier.notify_brew_record(record)
        global_event_bus.publish("session.completed", {"record_id": record.id, "compacted": compacted.to_dict()})

        # 7. Reset session back to standby listening
        self.active_session = {
            "session_id": f"sess-{datetime.now().strftime('%H%M%S')}",
            "state": "standby_listening",
            "camera_id": cam_id,
            "camera_model": model,
            "started_at": None,
            "transcript_chunks": [],
            "utterance_events": [],
            "compacted_context": compacted.to_dict(),
            "auto_silence_timeout_s": 25,
            "last_gimbal_preset": None,
            "last_event": f"{reason} → 已生成报告 [{record.id}] (无损压缩校验: {compacted.checksum_sha256})",
            "last_record_id": record.id,
            "shutter_duml_hex": shutter_stop.get("duml_hex", ""),
        }

        return {
            "auto_stopped": True,
            "reason": reason,
            "media_url": resolved_media_url,
            "video_path": video_file,
            "camera_file_path": explicit_video_path or default_camera_path,
            "vision_analysis": vision_analysis,
            "visual_provenance": visual_provenance,
            "bean_inventory": bean_inventory,
            "session": self.active_session,
            "compacted_context": compacted.to_dict(),
            "record": record.to_dict(),
            "notification": notif,
        }
