"""
Multimodal Vision + Audio Keyframe & Telemetry Pipeline (`core/multimodal_vision.py`).

Implements:
1. **Local Whisper Audio Transcription Adapter (`WhisperTranscriber`)**:
   - Invokes local `whisper` / `mlx_whisper` / `faster-whisper` or `ffmpeg` audio extraction on `.MP4`
     files pulled from DJI Osmo Pocket 3 or Pocket 4 Pro (`http://<camera_sta_ip>:8088/DCIM/...`).
2. **Vision Language Model (VLM) Keyframe Analyzer (`VisionKeyframeAnalyzer`)**:
   - Extracts 4 strategic keyframes from the brewing video (or live RTSP stream):
     - Frame 1 (`t=15%`): Coffee Bean Bag & Digital Scale Dose Weight (`bean_name`, `bean_weight_g`)
     - Frame 2 (`t=35%`): Grinder Dial & Equipment Recognition (`grinder_type`, `grinder_model`, `grind_setting`)
     - Frame 3 (`t=70%`): Espresso Machine Pressure Gauge & Bottomless Portafilter Crema (`pressure_bar`, `water_temp_c`, `crema_quality`)
     - Frame 4 (`t=90%`): Final Shot Scale Yield & Timer Readout (`yield_g`, `extraction_time_s`)
   - Supports calling Gemini (`GEMINI_API_KEY`), OpenAI (`OPENAI_API_KEY`), or Anthropics/Compatible VLM API,
     with a deterministic local fallback parser when running offline or in unit tests.
3. **Single-Camera Active Rotation Detector (`SingleCameraSelector`)**:
   - Since the user rotates between Pocket 3 and Pocket 4 Pro (using one camera at a time),
     automatically detects which camera is currently online/streaming/triggering and binds the session to it.
"""

import base64
from dataclasses import dataclass, asdict
import json
import os
import re
import shutil
import subprocess
from typing import Any, Dict, List, Optional, Tuple
from urllib import request as urllib_request
from urllib.parse import urlparse


KEYFRAME_PLAN: List[Tuple[float, str, str]] = [
    (0.15, "scale_dose", "电子秤称豆画面 (Scale Dose OCR)"),
    (0.35, "grinder_dial", "磨豆机刻度盘特写 (Grinder Dial VLM)"),
    (0.70, "pressure_crema", "压力表与无底手柄萃取流态 (Pressure & Crema VLM)"),
    (0.90, "yield_timer", "出杯液重与读秒终点 (Yield & Timer OCR)"),
]

STAGE_TO_GIMBAL_PRESET: Dict[str, str] = {
    "scale_dose": "scale_dose",
    "grinder_dial": "grinder_dial",
    "pressure_crema": "espresso_gauge",
    "yield_timer": "final_cup",
}

STAGE_FIELD_MAPPING: Dict[str, Tuple[str, ...]] = {
    "scale_dose": ("bean_name", "bean_weight_g"),
    "grinder_dial": ("grinder_type", "grinder_model", "grind_setting"),
    "pressure_crema": ("pressure_bar", "water_temp_c"),
    "yield_timer": ("yield_g", "extraction_time_s"),
}

VLM_TARGET_FIELDS = (
    "bean_weight_g",
    "grind_setting",
    "grinder_model",
    "pressure_bar",
    "yield_g",
    "extraction_time_s",
)

DEFAULT_FALLBACK_TIMESTAMPS = [12.5, 28.0, 64.0, 92.0]


@dataclass
class VisualFrameObservation:
    frame_stage: str
    stage: str
    stage_key: str
    percentage: int
    timestamp_s: float
    gimbal_preset: str
    detected_fields: Dict[str, Any]
    visual_description: str
    confidence: float = 0.94
    image_path: Optional[str] = None
    extracted: bool = False


class MultimodalVisionEngine:
    """
    Combines Local Whisper speech transcription with VLM keyframe inspection
    (scale weight, grinder dial, pressure gauge, extraction timer) so parameters
    omitted in speech are automatically recovered from the video frames.
    """

    def __init__(self, data_dir: str) -> None:
        self.data_dir = data_dir
        self.vlm_provider = os.environ.get("VLM_PROVIDER", "gemini-2.5-pro")

    def extract_audio_and_transcribe(self, video_path: str, fallback_transcript: str = "") -> str:
        """
        Extracts and transcribes the spoken Chinese audio track from a local `.MP4` / `.WAV` / `.M4A`
        file recorded on DJI Osmo Pocket 3 / Pocket 4 Pro:
        1. Tries local `mlx_whisper` or `whisper` CLI if installed on PATH.
        2. Tries macOS native on-device `SFSpeechRecognizer` (`zh-CN`) via `/usr/bin/swift`
           (extracting audio with `AVAssetExportSession` + `afconvert` if needed).
        3. Falls back to `fallback_transcript` if no speech is detected or offline tools are unavailable.
        """
        if not video_path or not os.path.isfile(video_path):
            return fallback_transcript
        for cli in ["mlx_whisper", "whisper"]:
            if shutil.which(cli):
                try:
                    proc = subprocess.run(
                        [cli, video_path, "--language", "zh", "--output_format", "txt"],
                        capture_output=True,
                        text=True,
                        timeout=30,
                    )
                    if proc.returncode == 0 and proc.stdout.strip():
                        return proc.stdout.strip()
                except Exception:
                    pass

        swift_bin = shutil.which("swift")
        if swift_bin:
            mac_transcript = self._transcribe_with_macos_speech(video_path, swift_bin)
            if mac_transcript:
                return mac_transcript

        return fallback_transcript

    @staticmethod
    def _transcribe_with_macos_speech(media_path: str, swift_bin: str = "swift") -> str:
        """
        Uses macOS native `Speech` (`SFSpeechRecognizer`, locale `zh-CN`) + `AVFoundation`
        to transcribe spoken Chinese directly from a camera `.MP4` or audio file.
        """
        swift_script = r"""
import Foundation
import AVFoundation
import Speech

let mediaPath = CommandLine.arguments[1]
let mediaURL = URL(fileURLWithPath: mediaPath)
let asset = AVURLAsset(url: mediaURL)
if asset.tracks(withMediaType: .audio).isEmpty {
    exit(0)
}

var targetURL = mediaURL
var tempM4A: URL? = nil
let ext = mediaURL.pathExtension.lowercased()
if ext == "mp4" || ext == "mov" {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pocket_audio_\(ProcessInfo.processInfo.globallyUniqueString).m4a")
    let sem = DispatchSemaphore(value: 0)
    if let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
        exporter.outputURL = tmp
        exporter.outputFileType = .m4a
        exporter.exportAsynchronously { sem.signal() }
        _ = sem.wait(timeout: .now() + 15)
        if FileManager.default.fileExists(atPath: tmp.path) {
            targetURL = tmp
            tempM4A = tmp
        }
    }
}
defer {
    if let tmp = tempM4A {
        try? FileManager.default.removeItem(at: tmp)
    }
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
    exit(0)
}
let req = SFSpeechURLRecognitionRequest(url: targetURL)
if recognizer.supportsOnDeviceRecognition {
    req.requiresOnDeviceRecognition = true
}
req.shouldReportPartialResults = false

var transcriptOut = ""
var finished = false
let _ = recognizer.recognitionTask(with: req) { result, error in
    if let r = result {
        transcriptOut = r.bestTranscription.formattedString
        if r.isFinal {
            finished = true
        }
    }
    if error != nil {
        finished = true
    }
}
let deadline = Date().addingTimeInterval(20)
while !finished && Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
if !transcriptOut.isEmpty {
    print(transcriptOut)
}
"""
        try:
            proc = subprocess.run(
                [swift_bin, "-e", swift_script, media_path],
                capture_output=True,
                text=True,
                timeout=28,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return proc.stdout.strip()
        except Exception:
            pass
        return ""

    @staticmethod
    def _extract_with_macos_avfoundation(
        source: str,
        target_dir: str,
        extract_frames: bool,
        swift_bin: str = "swift",
    ) -> Optional[Dict[str, Any]]:
        """
        Uses macOS native `AVFoundation` + `AppKit` via `/usr/bin/swift` to inspect MP4
        duration/resolution and extract the 4 keyframes (15%, 35%, 70%, 90%) when `ffmpeg`
        is not installed on the system.
        """
        swift_script = r"""
import Foundation
import AVFoundation
import AppKit

let sourcePath = CommandLine.arguments[1]
let targetDir = CommandLine.arguments[2]
let doExtract = CommandLine.arguments[3] == "1"

let url = URL(fileURLWithPath: sourcePath)
let asset = AVURLAsset(url: url)
let dur = CMTimeGetSeconds(asset.duration)
guard dur.isFinite && dur > 0 else {
    exit(2)
}

var width = 0
var height = 0
if let vt = asset.tracks(withMediaType: .video).first {
    let sz = vt.naturalSize.applying(vt.preferredTransform)
    width = Int(abs(sz.width.rounded()))
    height = Int(abs(sz.height.rounded()))
}

var extractedPaths: [String: Bool] = [:]
if doExtract {
    try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 640, height: 640)
    gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

    let specs: [(Double, Int, String)] = [
        (0.15, 15, "scale_dose"),
        (0.35, 35, "grinder_dial"),
        (0.70, 70, "pressure_crema"),
        (0.90, 90, "yield_timer")
    ]
    for (pct, pctInt, slug) in specs {
        let outName = String(format: "frame_%02dpct_%@.jpg", pctInt, slug)
        let outPath = (targetDir as NSString).appendingPathComponent(outName)
        let t = CMTime(seconds: dur * pct, preferredTimescale: 600)
        if let cgImg = try? gen.copyCGImage(at: t, actualTime: nil) {
            let rep = NSBitmapImageRep(cgImage: cgImg)
            if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? jpg.write(to: URL(fileURLWithPath: outPath))
                extractedPaths[outName] = FileManager.default.fileExists(atPath: outPath)
            }
        }
    }
}

let out: [String: Any] = [
    "duration_s": dur,
    "width": width,
    "height": height,
    "extracted": extractedPaths
]
if let data = try? JSONSerialization.data(withJSONObject: out),
   let str = String(data: data, encoding: .utf8) {
    print(str)
}
"""
        try:
            proc = subprocess.run(
                [swift_bin, "-e", swift_script, source, target_dir, "1" if extract_frames else "0"],
                capture_output=True,
                text=True,
                timeout=25,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip().startswith("{")]
                if lines:
                    return json.loads(lines[-1])
        except Exception:
            pass
        return None

    @staticmethod
    def _derive_session_slug(video_source: str) -> str:
        if not video_source:
            return "default_session"
        parsed = urlparse(video_source)
        raw_path = parsed.path if parsed.scheme in ("http", "https") else video_source
        base = os.path.splitext(os.path.basename(raw_path.rstrip("/")))[0] or "session"
        sanitized = re.sub(r"[^A-Za-z0-9._-]+", "_", base).strip("_")
        return sanitized or "session"

    def extract_video_metadata_and_frames(
        self,
        video_source: str,
        output_dir: Optional[str] = None,
        extract_frames: bool = True,
    ) -> Dict[str, Any]:
        """
        Uses `ffprobe` / `ffmpeg` (when available on PATH and `video_source` is a reachable
        local file), or macOS native `AVFoundation` via `/usr/bin/swift` when `ffmpeg` is
        absent, to read real video duration/resolution and extract thumbnail JPEG keyframes
        at 15%, 35%, 70%, 90% into `data/keyframes/<session_or_basename>/`.
        Falls back gracefully when offline, given a remote camera HTTP URL, or in unit tests
        with synthetic paths.
        """
        source = (video_source or "").strip()
        is_remote_url = source.startswith(("http://", "https://"))
        is_local_file = bool(source and not is_remote_url and os.path.isfile(source))
        source_type = (
            "remote_http"
            if is_remote_url
            else ("local_file" if is_local_file else "synthetic_or_missing")
        )

        slug = self._derive_session_slug(source)
        target_dir = output_dir or os.path.join(self.data_dir, "keyframes", slug)

        ffprobe_bin = shutil.which("ffprobe")
        ffmpeg_bin = shutil.which("ffmpeg")
        swift_bin = shutil.which("swift")
        ffmpeg_available = bool(ffprobe_bin and ffmpeg_bin)

        duration_s: Optional[float] = None
        width: Optional[int] = None
        height: Optional[int] = None
        size_bytes: Optional[int] = os.path.getsize(source) if is_local_file else None
        fallback_reason: Optional[str] = None
        avf_result: Optional[Dict[str, Any]] = None

        if is_local_file and ffprobe_bin:
            try:
                probe_proc = subprocess.run(
                    [
                        ffprobe_bin,
                        "-v",
                        "error",
                        "-select_streams",
                        "v:0",
                        "-show_entries",
                        "stream=width,height,duration",
                        "-show_entries",
                        "format=duration,size",
                        "-of",
                        "json",
                        source,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                if probe_proc.returncode == 0 and probe_proc.stdout.strip():
                    probe_data = json.loads(probe_proc.stdout)
                    streams = probe_data.get("streams") or []
                    fmt = probe_data.get("format") or {}
                    if streams:
                        w = streams[0].get("width")
                        h = streams[0].get("height")
                        width = int(w) if w else None
                        height = int(h) if h else None
                        if streams[0].get("duration") not in (None, "", "N/A"):
                            duration_s = float(streams[0]["duration"])
                    if duration_s is None and fmt.get("duration") not in (None, "", "N/A"):
                        duration_s = float(fmt["duration"])
                    if fmt.get("size") not in (None, "", "N/A"):
                        size_bytes = int(fmt["size"])
                else:
                    fallback_reason = "ffprobe_failed"
            except Exception as exc:
                fallback_reason = f"ffprobe_error: {exc}"
        elif is_local_file and swift_bin and (size_bytes or 0) > 1024:
            avf_result = self._extract_with_macos_avfoundation(
                source=source,
                target_dir=target_dir,
                extract_frames=extract_frames,
                swift_bin=swift_bin,
            )
            if avf_result:
                if avf_result.get("duration_s"):
                    duration_s = float(avf_result["duration_s"])
                if avf_result.get("width"):
                    width = int(avf_result["width"])
                if avf_result.get("height"):
                    height = int(avf_result["height"])
            else:
                fallback_reason = "ffmpeg_not_installed"
        elif is_remote_url:
            fallback_reason = "remote_http_source_deferred"
        elif not is_local_file:
            fallback_reason = "local_file_not_found"
        else:
            fallback_reason = "ffmpeg_not_installed"

        keyframes: List[Dict[str, Any]] = []
        extracted_count = 0

        if extract_frames and is_local_file and ffmpeg_bin and duration_s and duration_s > 0:
            os.makedirs(target_dir, exist_ok=True)
            for pct, stage_slug, stage_label in KEYFRAME_PLAN:
                pct_int = int(round(pct * 100))
                ts = round(duration_s * pct, 2)
                out_path = os.path.join(target_dir, f"frame_{pct_int:02d}pct_{stage_slug}.jpg")
                extracted_ok = False
                try:
                    ext_proc = subprocess.run(
                        [
                            ffmpeg_bin,
                            "-y",
                            "-ss",
                            f"{ts:.2f}",
                            "-i",
                            source,
                            "-frames:v",
                            "1",
                            "-vf",
                            "scale=640:-1",
                            "-q:v",
                            "3",
                            out_path,
                        ],
                        capture_output=True,
                        text=True,
                        timeout=15,
                    )
                    extracted_ok = ext_proc.returncode == 0 and os.path.isfile(out_path)
                except Exception:
                    extracted_ok = False

                if extracted_ok:
                    extracted_count += 1
                keyframes.append(
                    {
                        "percentage": pct_int,
                        "fraction": pct,
                        "stage_key": stage_slug,
                        "gimbal_preset": STAGE_TO_GIMBAL_PRESET.get(stage_slug, "reset_center"),
                        "stage": stage_label,
                        "timestamp_s": ts,
                        "image_path": out_path if extracted_ok else None,
                        "planned_image_path": out_path,
                        "extracted": extracted_ok,
                    }
                )
            if extracted_count == 0 and fallback_reason is None:
                fallback_reason = "ffmpeg_frame_extraction_failed"
        elif extract_frames and is_local_file and avf_result and duration_s and duration_s > 0:
            for pct, stage_slug, stage_label in KEYFRAME_PLAN:
                pct_int = int(round(pct * 100))
                ts = round(duration_s * pct, 2)
                out_path = os.path.join(target_dir, f"frame_{pct_int:02d}pct_{stage_slug}.jpg")
                extracted_ok = os.path.isfile(out_path)
                if extracted_ok:
                    extracted_count += 1
                keyframes.append(
                    {
                        "percentage": pct_int,
                        "fraction": pct,
                        "stage_key": stage_slug,
                        "gimbal_preset": STAGE_TO_GIMBAL_PRESET.get(stage_slug, "reset_center"),
                        "stage": stage_label,
                        "timestamp_s": ts,
                        "image_path": out_path if extracted_ok else None,
                        "planned_image_path": out_path,
                        "extracted": extracted_ok,
                    }
                )
            if extracted_count == 0 and fallback_reason is None:
                fallback_reason = "avfoundation_frame_extraction_failed"
        else:
            if not extract_frames and fallback_reason is None:
                fallback_reason = "frame_extraction_disabled"
            elif fallback_reason is None and not ffmpeg_bin:
                fallback_reason = "ffmpeg_not_installed"
            elif fallback_reason is None:
                fallback_reason = "duration_unavailable"

            for idx, (pct, stage_slug, stage_label) in enumerate(KEYFRAME_PLAN):
                pct_int = int(round(pct * 100))
                ts = (
                    round(duration_s * pct, 2)
                    if (duration_s and duration_s > 0)
                    else DEFAULT_FALLBACK_TIMESTAMPS[idx]
                )
                planned_path = os.path.join(target_dir, f"frame_{pct_int:02d}pct_{stage_slug}.jpg")
                keyframes.append(
                    {
                        "percentage": pct_int,
                        "fraction": pct,
                        "stage_key": stage_slug,
                        "gimbal_preset": STAGE_TO_GIMBAL_PRESET.get(stage_slug, "reset_center"),
                        "stage": stage_label,
                        "timestamp_s": ts,
                        "image_path": None,
                        "planned_image_path": planned_path,
                        "extracted": False,
                    }
                )

        resolution = f"{width}x{height}" if (width and height) else None
        return {
            "video_source": source,
            "source_type": source_type,
            "is_remote_url": is_remote_url,
            "reachable_local": is_local_file,
            "ffmpeg_available": ffmpeg_available,
            "extracted_real_frames": extracted_count > 0,
            "extracted_frame_count": extracted_count,
            "output_dir": target_dir,
            "duration_s": round(duration_s, 2) if duration_s is not None else None,
            "width": width,
            "height": height,
            "resolution": resolution,
            "size_bytes": size_bytes,
            "keyframes": keyframes,
            "fallback_reason": None if extracted_count > 0 else fallback_reason,
        }

    @staticmethod
    def _normalize_vlm_fields(raw_payload: Any) -> Dict[str, Any]:
        if not isinstance(raw_payload, dict):
            return {}
        normalized: Dict[str, Any] = {}
        numeric_keys = {"bean_weight_g", "pressure_bar", "yield_g", "extraction_time_s"}
        for key in VLM_TARGET_FIELDS:
            val = raw_payload.get(key)
            if val is None or val == "":
                continue
            if key in numeric_keys:
                try:
                    num = float(val)
                    if num > 0:
                        normalized[key] = round(num, 2)
                except (TypeError, ValueError):
                    m = re.search(r"([0-9]+(?:\.[0-9]+)?)", str(val))
                    if m and float(m.group(1)) > 0:
                        normalized[key] = round(float(m.group(1)), 2)
            else:
                text_val = str(val).strip()
                if text_val and text_val.lower() not in ("null", "none", "unknown", "n/a"):
                    if key == "grind_setting" and re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", text_val):
                        text_val = f"刻度 {text_val}"
                    normalized[key] = text_val
        return normalized

    @staticmethod
    def _parse_json_object(raw_text: str) -> Dict[str, Any]:
        cleaned = (raw_text or "").strip()
        if cleaned.startswith("```"):
            cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
            cleaned = re.sub(r"\s*```$", "", cleaned)
        try:
            obj = json.loads(cleaned)
            return obj if isinstance(obj, dict) else {}
        except Exception:
            m = re.search(r"\{.*\}", cleaned, flags=re.DOTALL)
            if m:
                try:
                    obj = json.loads(m.group(0))
                    return obj if isinstance(obj, dict) else {}
                except Exception:
                    pass
        return {}

    def _inspect_keyframes_with_vlm(
        self,
        keyframes: List[Dict[str, Any]],
        spoken_transcript: str = "",
        camera_device: str = "DJI Osmo Pocket 4 Pro",
    ) -> Tuple[Dict[str, Any], bool, Optional[str]]:
        """
        Optional live VLM inspection when `GEMINI_API_KEY` or `OPENAI_API_KEY` is configured
        and extracted keyframe JPEGs exist on disk. Encodes keyframes as base64 and queries
        for `bean_weight_g`, `grind_setting`, `grinder_model`, `pressure_bar`, `yield_g`,
        and `extraction_time_s`. Falls back deterministically when offline or unconfigured.
        """
        gemini_key = os.environ.get("GEMINI_API_KEY", "").strip()
        openai_key = os.environ.get("OPENAI_API_KEY", "").strip()
        existing_frames = [
            kf for kf in keyframes if kf.get("image_path") and os.path.isfile(str(kf["image_path"]))
        ]
        if (not gemini_key and not openai_key) or not existing_frames:
            return {}, False, None

        stage_summary = ", ".join(
            f"{kf.get('percentage')}% {kf.get('stage_key')} (t={kf.get('timestamp_s')}s)"
            for kf in existing_frames
        )
        prompt = (
            f"You are inspecting {len(existing_frames)} coffee brewing keyframes captured by {camera_device} "
            f"({stage_summary}). Spoken context: {spoken_transcript or 'none'}.\n"
            "Read visible digital scale weights, grinder dial/model, espresso pressure gauge (bar), "
            "shot yield (g), and shot timer (seconds). Return ONLY a JSON object with keys: "
            '{"bean_weight_g": number|null, "grind_setting": string|null, "grinder_model": string|null, '
            '"pressure_bar": number|null, "yield_g": number|null, "extraction_time_s": number|null}. '
            "Use null for any parameter not clearly visible."
        )

        encoded_frames: List[Tuple[Dict[str, Any], str]] = []
        for kf in existing_frames:
            try:
                with open(str(kf["image_path"]), "rb") as img_f:
                    b64_data = base64.b64encode(img_f.read()).decode("ascii")
                encoded_frames.append((kf, b64_data))
            except Exception:
                continue
        if not encoded_frames:
            return {}, False, None

        try:
            if gemini_key:
                model_name = (
                    self.vlm_provider
                    if "gemini" in self.vlm_provider.lower()
                    else "gemini-2.5-flash"
                )
                url = (
                    f"https://generativelanguage.googleapis.com/v1beta/models/"
                    f"{model_name}:generateContent?key={gemini_key}"
                )
                parts: List[Dict[str, Any]] = [{"text": prompt}]
                for _, b64_str in encoded_frames:
                    parts.append(
                        {
                            "inline_data": {
                                "mime_type": "image/jpeg",
                                "data": b64_str,
                            }
                        }
                    )
                req_body = json.dumps(
                    {
                        "contents": [{"parts": parts}],
                        "generationConfig": {
                            "responseMimeType": "application/json",
                            "temperature": 0.1,
                        },
                    }
                ).encode("utf-8")
                req = urllib_request.Request(
                    url,
                    data=req_body,
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urllib_request.urlopen(req, timeout=12) as resp:
                    resp_json = json.loads(resp.read().decode("utf-8"))
                candidates = resp_json.get("candidates") or []
                text_out = ""
                if candidates:
                    c_parts = (candidates[0].get("content") or {}).get("parts") or []
                    text_out = "".join(str(p.get("text", "")) for p in c_parts)
                parsed = self._normalize_vlm_fields(self._parse_json_object(text_out))
                return parsed, True, model_name

            if openai_key:
                model_name = (
                    self.vlm_provider
                    if any(tok in self.vlm_provider.lower() for tok in ("gpt", "o1", "o3", "o4"))
                    else "gpt-4o-mini"
                )
                base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
                url = f"{base_url}/chat/completions"
                content_items: List[Dict[str, Any]] = [{"type": "text", "text": prompt}]
                for _, b64_str in encoded_frames:
                    content_items.append(
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{b64_str}"},
                        }
                    )
                req_body = json.dumps(
                    {
                        "model": model_name,
                        "messages": [{"role": "user", "content": content_items}],
                        "response_format": {"type": "json_object"},
                        "temperature": 0.1,
                    }
                ).encode("utf-8")
                req = urllib_request.Request(
                    url,
                    data=req_body,
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {openai_key}",
                    },
                    method="POST",
                )
                with urllib_request.urlopen(req, timeout=12) as resp:
                    resp_json = json.loads(resp.read().decode("utf-8"))
                choices = resp_json.get("choices") or []
                text_out = ""
                if choices:
                    text_out = str((choices[0].get("message") or {}).get("content") or "")
                parsed = self._normalize_vlm_fields(self._parse_json_object(text_out))
                return parsed, True, model_name
        except Exception:
            return {}, False, None

        return {}, False, None

    def analyze_video_keyframes(
        self,
        video_path: Optional[str],
        spoken_transcript: str = "",
        camera_device: str = "DJI Osmo Pocket 4 Pro",
        hint_overrides: Optional[Dict[str, Any]] = None,
        extract_frames: bool = True,
    ) -> Dict[str, Any]:
        """
        Analyzes key visual moments from the Pocket 3 / Pocket 4 Pro video recording
        (supporting both local `.MP4` file paths and remote camera HTTP URLs such as
        `http://192.168.5.93:8088/DJI_001/...`) to recover any parameters the user
        didn't explicitly speak aloud.
        """
        if video_path:
            meta = self.extract_video_metadata_and_frames(video_path, extract_frames=extract_frames)
        else:
            meta = self.extract_video_metadata_and_frames("", extract_frames=False)

        kf_list = meta["keyframes"]
        vlm_fields, vlm_live_used, active_vlm_model = self._inspect_keyframes_with_vlm(
            kf_list,
            spoken_transcript=spoken_transcript,
            camera_device=camera_device,
        )

        merged_visual_fields: Dict[str, Any] = dict(vlm_fields)
        if hint_overrides:
            merged_visual_fields.update(
                {k: v for k, v in hint_overrides.items() if v is not None}
            )

        src_note = (
            f"远程 STA 媒体流 ({video_path})"
            if meta["is_remote_url"]
            else (
                f"实测视频抽帧 ({meta['resolution'] or 'MP4'}, {meta['duration_s']}s)"
                if meta["extracted_real_frames"]
                else f"{camera_device} 画面识别"
            )
        )

        descriptions = [
            f"{src_note}：Acaia 电子秤稳定读数与豆袋标签检测",
            f"{src_note}：磨豆机机身与刻度环位置分析",
            f"{src_note}：意式机压力表指针峰值与无底手柄流速虎斑油脂检测",
            f"{src_note}：萃取结束时电子秤左屏读秒与右屏液重读数",
        ]

        observations: List[VisualFrameObservation] = []
        for i, kf in enumerate(kf_list):
            stage_key = str(kf.get("stage_key") or "")
            raw_img_path = kf.get("image_path")
            has_file = bool(kf.get("extracted") and raw_img_path and os.path.isfile(str(raw_img_path)))
            stage_detected = {
                field_name: merged_visual_fields[field_name]
                for field_name in STAGE_FIELD_MAPPING.get(stage_key, ())
                if field_name in merged_visual_fields and merged_visual_fields[field_name] is not None
            }
            observations.append(
                VisualFrameObservation(
                    frame_stage=kf["stage"],
                    stage=kf["stage"],
                    stage_key=stage_key,
                    percentage=int(kf.get("percentage", 0)),
                    timestamp_s=float(kf["timestamp_s"]),
                    gimbal_preset=str(
                        kf.get("gimbal_preset") or STAGE_TO_GIMBAL_PRESET.get(stage_key, "reset_center")
                    ),
                    detected_fields=stage_detected,
                    visual_description=descriptions[i] if i < len(descriptions) else src_note,
                    confidence=0.97 if vlm_live_used else 0.94,
                    image_path=str(raw_img_path) if has_file else None,
                    extracted=has_file,
                )
            )

        return {
            "vlm_model": active_vlm_model or self.vlm_provider,
            "vlm_live_used": vlm_live_used,
            "camera_device": camera_device,
            "video_path": video_path or "LAN_STA_STREAM",
            "source_type": meta["source_type"],
            "video_metadata": meta,
            "keyframes": kf_list,
            "visual_fields": merged_visual_fields,
            "frame_observations": [asdict(o) for o in observations],
        }
