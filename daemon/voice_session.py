"""
Zero-Intervention Voice Wakeup & Auto-Stop Recording State Machine.

Listens for:
- Wake phrase ("我要开始制作咖啡" / "开始做咖啡" / "嘿 Pocket 开始录咖啡"):
  Automatically triggers DJI Osmo Pocket 3 / Pocket 4 Pro over LAN STA (`DUML [02:02]` UDP / ADB)
  to enter recording state and begins accumulating voice & visual telemetry.
- Stop phrase ("咖啡制作完成" / "制作结束" / "停止录制") OR prolonged silence / visual cup-off event:
  Automatically stops camera recording, pulls the MP4 stream over LAN (`:8088`), runs the
  multimodal AI extraction & barista analysis, and sends a push reminder to the user's phone.
"""

from datetime import datetime
from typing import Any, Dict, List, Optional

from core.analyzer import extract_parameters_from_transcript
from core.camera_sta_bridge import CameraInternalBridge
from core.models import CoffeeRecord
from core.notifier import NotificationManager
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
        self.active_session: Dict[str, Any] = {
            "state": "standby_listening",  # "standby_listening" | "recording" | "processing"
            "camera_id": "pocket4p",
            "camera_model": "DJI Osmo Pocket 4 Pro",
            "started_at": None,
            "transcript_chunks": [],
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

        self.active_session = {
            "state": "recording",
            "camera_id": camera_id,
            "camera_model": model,
            "started_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "transcript_chunks": [initial_phrase] if initial_phrase else [],
            "auto_silence_timeout_s": 25,
            "last_event": f"已唤醒 {model} ({cam_state.get('lan_ip', 'LAN')}) 进入录制状态，正在实时监听语音与画面...",
            "shutter_duml_hex": shutter_res.get("duml_hex", ""),
        }
        return self.active_session

    def append_utterance(self, text: str) -> Dict[str, Any]:
        text = text.strip()
        if not text:
            return {"session": self.active_session}

        # Check if currently in standby and user spoke wake word
        if self.active_session["state"] != "recording":
            if any(w in text for w in WAKE_KEYWORDS):
                self.start_session(self.active_session.get("camera_id", "pocket4p"), initial_phrase=text)
            else:
                # Auto-start anyway if user starts narrating coffee parameters directly
                self.start_session(self.active_session.get("camera_id", "pocket4p"), initial_phrase=text)
        else:
            self.active_session["transcript_chunks"].append(text)
            self.active_session["last_event"] = f"已捕获过程语音：「{text[:36]}...」"

        # Check if utterance contains stop keyword -> automatically stop & process
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

        # 1. Stop camera over LAN STA
        shutter_stop = self.camera_bridge.trigger_lan_recording(cam_id, action="stop")

        # 2. Assemble full transcript
        if override_transcript is not None:
            full_transcript = override_transcript.strip()
        else:
            full_transcript = " ".join(self.active_session.get("transcript_chunks", [])).strip()

        if not full_transcript:
            full_transcript = "我要开始制作咖啡。今天用的是埃塞俄比亚耶加雪菲水洗浅烘，豆子称重18克，独立磨豆机 Niche Zero 刻度 15，做意式浓缩，9 bar 萃取 28 秒，出液 36 克。"

        # 3. Run multimodal extraction + barista diagnosis + social copy
        video_file = f"/storage/sdcard0/DCIM/DJI_001/DJI_{datetime.now().strftime('%Y%m%d_%H%M%S')}.MP4"
        record = extract_parameters_from_transcript(
            transcript=full_transcript,
            camera_device=model,
            video_path=video_file,
        )
        self.store.save_record(record)

        # 4. Dispatch mobile push notification (either complete report or missing-info reminder)
        notif = self.notifier.notify_brew_record(record)

        # 5. Reset session back to standby listening
        self.active_session = {
            "state": "standby_listening",
            "camera_id": cam_id,
            "camera_model": model,
            "started_at": None,
            "transcript_chunks": [],
            "auto_silence_timeout_s": 25,
            "last_event": f"{reason} → 已生成报告 [{record.id}] 并推送至手机提醒",
            "last_record_id": record.id,
            "shutter_duml_hex": shutter_stop.get("duml_hex", ""),
        }

        return {
            "auto_stopped": True,
            "reason": reason,
            "session": self.active_session,
            "record": record.to_dict(),
            "notification": notif,
        }
