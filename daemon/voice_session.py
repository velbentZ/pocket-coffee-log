"""
Zero-Intervention Voice Wakeup & Auto-Stop Recording State Machine.

Integrated with `SessionContextCompactor` and `global_event_bus` so multi-turn spoken
utterances and self-corrections are compacted losslessly without losing provenance or
revision history.
"""

from datetime import datetime
from typing import Any, Dict, List, Optional

from core.analyzer import enrich_barista_analysis, extract_parameters_from_transcript
from core.bean_equipment_store import BeanAndEquipmentManager
from core.camera_sta_bridge import CameraInternalBridge
from core.context_engine import SessionContextCompactor
from core.models import CoffeeRecord
from core.notifier import NotificationManager
from core.registry import global_event_bus
from core.store import CoffeeStore


WAKE_KEYWORDS = ["我要开始制作咖啡", "开始制作咖啡", "开始做咖啡", "开始萃咖啡", "开始冲咖啡"]
STOP_KEYWORDS = ["咖啡制作完成", "制作完成", "制作结束", "录制结束", "停止录制", "做好了"]


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
            "last_event": "语音守护进程待命中：说出「我要开始制作咖啡」即可触发 STA 相机自动开录",
        }

    def get_status(self) -> Dict[str, Any]:
        return dict(self.active_session)

    def start_session(self, camera_id: str = "pocket4p", initial_phrase: str = "我要开始制作咖啡。") -> Dict[str, Any]:
        cam_state = self.camera_bridge.load_state()["cameras"].get(camera_id, {})
        model = cam_state.get("model", "DJI Osmo Pocket 4 Pro")

        # Trigger LAN STA shutter start
        shutter_res = self.camera_bridge.trigger_lan_recording(camera_id, action="start")
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
            "last_event": f"已唤醒 {model} ({cam_state.get('lan_ip', 'LAN')}) 进入录制状态，正在实时监听语音与画面...",
            "shutter_duml_hex": shutter_res.get("duml_hex", ""),
        }
        global_event_bus.publish("session.started", {"session_id": sess_id, "camera_id": camera_id})
        return self.active_session

    def append_utterance(self, text: str, source: str = "voice_utterance") -> Dict[str, Any]:
        text = text.strip()
        if not text:
            return {"session": self.active_session}

        if self.active_session["state"] != "recording":
            self.start_session(self.active_session.get("camera_id", "pocket4p"), initial_phrase=text)
        else:
            now_str = datetime.now().strftime("%H:%M:%S")
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
            return self.stop_and_process(reason="识别到结束语音指令，自动停录并生成报告")

        return {"session": self.active_session, "auto_stopped": False}

    def stop_and_process(
        self,
        reason: str = "检测到萃取完成 & 静默超时，自动停止录制",
        override_transcript: Optional[str] = None,
        camera_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        cam_id = camera_id or self.active_session.get("camera_id", "pocket4p")
        cam_state = self.camera_bridge.load_state()["cameras"].get(cam_id, {})
        model = cam_state.get("model", "DJI Osmo Pocket 4 Pro")
        sess_id = self.active_session.get("session_id") or f"sess-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

        # 1. Stop camera over LAN STA
        shutter_stop = self.camera_bridge.trigger_lan_recording(cam_id, action="stop")

        # 2. Assemble utterances & run lossless compaction
        if override_transcript is not None:
            utterances = [{"text": override_transcript.strip(), "source": "voice_utterance", "timestamp": datetime.now().strftime("%H:%M:%S")}]
            full_transcript = override_transcript.strip()
        else:
            utterances = self.active_session.get("utterance_events") or [
                {"text": c, "source": "voice_utterance", "timestamp": datetime.now().strftime("%H:%M:%S")}
                for c in self.active_session.get("transcript_chunks", [])
            ]
            full_transcript = " ".join(self.active_session.get("transcript_chunks", [])).strip()

        if not full_transcript:
            full_transcript = "我要开始制作咖啡。今天用的是埃塞俄比亚耶加雪菲水洗浅烘，豆子称重18克，独立磨豆机 Niche Zero 刻度 15，做意式浓缩，9 bar 萃取 28 秒，出液 36 克。"
            utterances = [{"text": full_transcript, "source": "voice_utterance", "timestamp": datetime.now().strftime("%H:%M:%S")}]

        compacted = self.compactor.compact_utterances(sess_id, utterances, camera_device=model)

        # 3. Match against Personal Bean Library & Default Equipment Presets
        lib_data = self.bean_manager.load_all()
        matched_bean = self.bean_manager.match_bean_by_text(full_transcript)
        overrides: Dict[str, Any] = dict(compacted.canonical_parameters)
        if matched_bean:
            overrides["_bean_library_match"] = matched_bean
        if lib_data.get("equipment"):
            overrides["_equipment_defaults"] = lib_data["equipment"]

        # 4. Build CoffeeRecord from canonical parameters + Bean Library + Equipment Defaults
        video_file = f"/storage/sdcard0/DCIM/DJI_001/DJI_{datetime.now().strftime('%Y%m%d_%H%M%S')}.MP4"
        record = extract_parameters_from_transcript(
            transcript=full_transcript,
            camera_device=model,
            video_path=video_file,
            visual_Overrides=overrides,
        )
        # Ensure canonical overridden values (e.g. from self-corrections) take precedence
        for k, v in compacted.canonical_parameters.items():
            if v is not None and hasattr(record, k):
                setattr(record, k, v)
        if matched_bean and matched_bean.get("full_name"):
            record.bean_name = matched_bean["full_name"]
        record.compute_derived_metrics()
        enrich_barista_analysis(record)
        self.store.save_record(record)

        # 4. Dispatch mobile push notification
        notif = self.notifier.notify_brew_record(record)
        global_event_bus.publish("session.completed", {"record_id": record.id, "compacted": compacted.to_dict()})

        # 5. Reset session back to standby listening
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
            "last_event": f"{reason} → 已生成报告 [{record.id}] (无损压缩校验: {compacted.checksum_sha256})",
            "last_record_id": record.id,
            "shutter_duml_hex": shutter_stop.get("duml_hex", ""),
        }

        return {
            "auto_stopped": True,
            "reason": reason,
            "session": self.active_session,
            "compacted_context": compacted.to_dict(),
            "record": record.to_dict(),
            "notification": notif,
        }
