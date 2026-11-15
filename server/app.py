"""
Pocket Coffee Log HTTP API & Web Server.

Provides REST endpoints for:
- `/api/state`: Full dashboard state (coffee records, active voice session, camera STA nodes, notification logs)
- `/api/voice/utterance`: Feed spoken voice transcript ("我要开始制作咖啡...", parameter narration, "制作完成")
- `/api/voice/stop`: Manually or automatically stop recording and trigger AI report generation
- `/api/records/supplement`: Fill in missing coffee parameters from mobile notification reminder
- `/api/camera/provision_sta`: Switch Pocket 3 / Pocket 4 Pro into persistent LAN STA mode & deploy internal agent
- `/api/camera/exec`: Execute root shell commands inside the camera over LAN ADB (:5555)
- `/api/camera/shutter`: Trigger LAN DUML [02:02] Start/Stop recording
- `/api/camera/webhook`: Receive automatic webhook from `/data/local/tmp/pocket_sta_agent.sh` inside camera when MP4 closes
- `/api/notifications/config`: Update WeCom / ServerChan / Bark / Feishu push credentials
"""

from http.server import HTTPServer, SimpleHTTPRequestHandler
import json
import os
import sys
from typing import Any, Dict
from urllib.parse import parse_qs, urlparse

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.analyzer import enrich_barista_analysis, extract_parameters_from_transcript
from core.camera_sta_bridge import CameraInternalBridge
from core.notifier import NotificationManager
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager


DATA_DIR = os.path.join(PROJECT_ROOT, "data")
STATIC_DIR = os.path.join(PROJECT_ROOT, "static")

store = CoffeeStore(DATA_DIR)
camera_bridge = CameraInternalBridge(DATA_DIR)
notifier = NotificationManager(DATA_DIR)
voice_manager = VoiceWakeupSessionManager(store, camera_bridge, notifier)

# Ensure initial notifications are seeded for the sample records if history is empty
if not notifier.get_history():
    for rec in reversed(store.list_records()):
        notifier.notify_brew_record(rec)


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

        if path == "/api/state":
            records = [r.to_dict() for r in store.list_records()]
            cam_state = camera_bridge.load_state()
            with open(camera_bridge.script_export_path, "r", encoding="utf-8") as f:
                agent_script = f.read()
            self._send_json({
                "ok": True,
                "records": records,
                "voice_session": voice_manager.get_status(),
                "camera_sta": cam_state,
                "on_camera_script": agent_script,
                "notifications": notifier.get_history(),
                "notification_config": notifier.load_config(),
            })
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
        body = self._read_json_body()

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
            reason = body.get("reason", "检测到咖啡制作结束，自动停止录制并生成报告")
            result = voice_manager.stop_and_process(
                reason=reason,
                override_transcript=transcript,
                camera_id=cam_id,
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

        if path == "/api/camera/webhook":
            # Triggered automatically by /data/local/tmp/pocket_sta_agent.sh inside Pocket 3 / Pocket 4 Pro
            camera_model = body.get("camera", "DJI Osmo Pocket 4 Pro")
            file_path = body.get("file_path", "/storage/sdcard0/DCIM/DJI_001/DJI_AUTO.MP4")
            transcript = body.get("transcript")
            res = voice_manager.stop_and_process(
                reason=f"相机内部守护进程推送新视频 ({os.path.basename(file_path)})",
                override_transcript=transcript,
            )
            self._send_json({"ok": True, "webhook_processed": True, **res})
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


def run_server(host: str = "0.0.0.0", port: int = 8765) -> None:
    server = HTTPServer((host, port), CoffeeRequestHandler)
    print(f"☕️ Pocket Coffee Log Server listening on http://{host}:{port}")
    server.serve_forever()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8765"))
    run_server(port=port)
