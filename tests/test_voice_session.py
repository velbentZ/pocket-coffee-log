import base64
import io
from datetime import timedelta
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from http.client import HTTPConnection
from http.server import HTTPServer
from threading import Thread
from unittest.mock import patch
import wave

from core.camera_sta_bridge import CameraInternalBridge, ON_CAMERA_AGENT_SCRIPT
from core.notifier import NotificationManager
from core.store import CoffeeStore
from daemon.voice_session import VoiceWakeupSessionManager
from server import app


def wav_payload(amplitude, seconds=2, offset=0):
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setparams((1, 2, 16000, 0, "NONE", ""))
        wav.writeframes(struct.pack("<hh", offset + amplitude, offset - amplitude) * (8000 * seconds))
    return dict(device_id="pocket4p", recording_active=False,
                wav_b64=base64.b64encode(output.getvalue()).decode())


class CameraVoiceTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.store = CoffeeStore(tmp.name)
        self.bridge = CameraInternalBridge(tmp.name)
        state = self.bridge.load_state()
        state["cameras"]["pocket4p"]["lan_ip"] = "192.168.5.94"
        self.bridge.save_state(state)
        self.manager = VoiceWakeupSessionManager(self.store, self.bridge, NotificationManager(tmp.name))
        for patcher in (
            patch.object(app, "voice_manager", self.manager),
            patch.object(self.bridge, "trigger_lan_recording"),
            patch.object(self.bridge, "move_gimbal_preset"),
            patch.object(self.manager.notifier, "notify_brew_record", return_value={}),
            patch.object(app.vision_engine, "extract_audio_and_transcribe"),
        ):
            self.addCleanup(patcher.stop)
            patcher.start()
        self.server = HTTPServer(("127.0.0.1", 0), app.CoffeeRequestHandler)
        thread = Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)

    def post(self, body, path="/api/camera/voice_chunk"):
        conn = HTTPConnection(*self.server.server_address, timeout=3)
        try:
            conn.request("POST", path, json.dumps(body), {"Content-Type": "application/json"})
            res = conn.getresponse()
            self.assertEqual(res.status, 200)
            return json.load(res)
        finally:
            conn.close()

    def say(self, text, recording=False):
        app.vision_engine.extract_audio_and_transcribe.return_value = text
        return self.post(dict(wav_payload(1200), recording_active=recording))

    def test_silence_skips_asr(self):
        self.assertEqual(self.post(wav_payload(3)), dict(
            ok=True, transcript="", command="none", action_token="ACTION:NONE"))
        app.vision_engine.extract_audio_and_transcribe.assert_not_called()

    def test_quiet_four_second_wav_is_centered_and_amplified(self):
        def recognize(path):
            with wave.open(path, "rb") as wav:
                self.assertEqual(wav.getnframes(), 64000)
                self.assertEqual(struct.unpack("<hh", wav.readframes(2)), (2400, -2400))
            return "开始录制"

        app.vision_engine.extract_audio_and_transcribe.side_effect = recognize
        self.assertEqual(self.post(wav_payload(200, seconds=4, offset=40))["command"], "start")

    def test_wav_length_limits(self):
        self.assertEqual(self.post(wav_payload(0, seconds=10))["command"], "none")
        with self.assertRaisesRegex(ValueError, "Invalid camera WAV length"):
            app._camera_voice_chunk(wav_payload(0, seconds=11))

    def test_split_wake_and_stop(self):
        self.assertEqual(self.say("我要开始")["command"], "none")
        self.assertEqual(self.say("鹿制")["command"], "start")
        self.assertEqual(self.say("请停止", True)["command"], "none")
        self.assertEqual(self.say("路制", True)["command"], "stop")

    def test_old_or_other_camera_chunk_does_not_complete_command(self):
        handle = self.manager.handle_camera_transcript
        self.assertEqual(handle("pocket3", "开始", False), "none")
        self.assertEqual(handle("pocket4p", "录制", False), "none")
        self.assertEqual(handle("pocket4p", "开始", False), "none")
        self.manager._last_camera_chunk["at"] -= timedelta(seconds=7)
        self.assertEqual(handle("pocket4p", "录制", False), "none")

    def test_wake_parameter_stop_and_webhook_retry(self):
        self.assertEqual(self.say("我要开始，制作咖啡")["action_token"], "ACTION:START")
        self.bridge.trigger_lan_recording.assert_not_called()
        with patch.object(self.manager, "append_utterance", wraps=self.manager.append_utterance) as append:
            self.assertEqual(self.say("豆子称重18克", True)["command"], "none")
            append.assert_called_once()
        before = len(self.store.list_records())
        self.assertEqual(self.say("咖啡做好了", True)["action_token"], "ACTION:STOP")
        self.assertEqual(len(self.store.list_records()), before)
        clip = dict(device_id="pocket4p", file_path="/camera/DJI_20000104000000_0040_D.MP4")
        done = self.post(clip, "/api/camera/webhook")
        self.assertEqual(done["record"]["bean_weight_g"], 18)
        self.post(clip, "/api/camera/webhook")
        self.assertEqual(len(self.store.list_records()), before + 1)
        self.manager.notifier.notify_brew_record.assert_called_once()
        self.bridge.trigger_lan_recording.assert_not_called()

    def test_wake_only_live_session_pulls_video_and_passes_audio_timing(self):
        self.assertEqual(self.say("开始录像")["command"], "start")
        self.assertEqual(self.say("停止录像", True)["command"], "stop")
        clip_name = "DJI_20261118174915_0044_D.MP4"
        local = Path(self.store.data_dir, clip_name)
        local.touch()
        segments = [{"text": "豆子称重18克", "timestamp_s": 5, "duration_s": 1}]
        with patch.object(self.bridge, "pull_latest_media",
                          return_value={"ok": True, "local_path": str(local)}) as pull, \
                patch.object(self.manager.vision_engine, "extract_audio_and_transcribe_segments",
                             return_value=("豆子称重18克", segments)) as asr, \
                patch.object(self.manager.vision_engine, "analyze_video_keyframes",
                             wraps=self.manager.vision_engine.analyze_video_keyframes) as analyze:
            result = self.manager.stop_and_process(media_finalized=True,
                media_url=f"http://192.168.5.94:8088/{clip_name}")
        pull.assert_called_once_with(device_id="pocket4p", filename=clip_name)
        asr.assert_called_once_with(str(local))
        self.assertEqual(result["record"]["bean_weight_g"], 18)
        self.assertEqual(analyze.call_args.kwargs["speech_segments"], segments)
        self.assertIn("开始录像", analyze.call_args.kwargs["spoken_transcript"])
        self.assertTrue(any(event["text"] == "停止录像"
                            for event in analyze.call_args.kwargs["utterance_events"]))

    def test_stop_when_only_camera_knows_it_is_recording(self):
        self.assertEqual(self.say("停止录象", True)["command"], "stop")

    def test_remote_listing_orders_by_sequence(self):
        old = "DJI_20260813100000_0034_D.MP4"
        new = "DJI_20000104100000_0040_D.MP4"
        with patch("core.camera_sta_bridge.urllib_request.urlopen", side_effect=OSError), \
                patch.object(self.bridge, "execute_internal_command", return_value={
                    "ok": True, "output": "\n".join(
                        f"-rw-r--r-- 1 0 0 500 Aug 13 10:00 {name}" for name in (old, new)
                    )
                }):
            self.assertEqual(self.bridge.list_remote_media()["latest"]["name"], new)


class AgentMediaTests(unittest.TestCase):
    def test_newest_mp4_uses_sequence_over_clock(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp, "DJI_001")
            folder.mkdir()
            old = folder / "DJI_20260813100000_0039_D.MP4"
            new = folder / "DJI_20000104100000_0040_D.MP4"
            new.touch()
            old.touch()
            os.utime(new, (100, 100))
            functions = ON_CAMERA_AGENT_SCRIPT.split("json_escape() {", 1)[1].split(
                "log 'Starting STA agent", 1)[0]
            result = subprocess.check_output(
                ["sh", "-c", 'bb() { "$@"; }; BB=bb; json_escape() {' + functions + "\nnewest_mp4"],
                env={**os.environ, "DCIM_DIR": tmp}, text=True).strip()
            self.assertEqual(result, str(new))
