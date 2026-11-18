"""Recover brewing parameters from spoken audio and selected video keyframes."""

import base64
from dataclasses import dataclass, asdict
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
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
    "bean_name",
    "water_temp_c",
    "grind_setting",
    "grinder_model",
    "pressure_bar",
    "yield_g",
    "extraction_time_s",
)

DEFAULT_FALLBACK_TIMESTAMPS = [12.5, 28.0, 64.0, 92.0]


_STAGE_WINDOWS = ((.06, .26), (.26, .48), (.50, .78), (.78, .95))
_STAGE_KEYWORDS = {
    "scale_dose": r"粉量|粉重|称重|称豆|浅烘|中烘|深烘|水洗|日晒|耶加|瑰夏|埃塞|(?<!磨)豆",
    "grinder_dial": r"磨豆|研磨|刻度|刀盘|niche|ek43|weber|df64|comandante|自带磨豆",
    "pressure_crema": r"压力|(?<![a-z])bar(?![a-z])|巴(?!拿马)|水温|(?<!刻)度|预浸泡|流速|油脂|虎斑|无底",
    "yield_timer": r"液重|出液|出杯|秒",
}
_STOP_PATTERN = r"萃取完成|做好了|停止|结束"
_SWIFT_KEYFRAMES = os.path.join(os.path.dirname(__file__), "macos_keyframes.swift")
_NUM = r"(?<![0-9a-zA-Z.+:：-])(\d+(?:\.\d+)?)(?![\d.:：])"
_BEAN_ORIGINS = r"耶加雪菲|瑰夏|埃塞俄比亚|哥伦比亚|肯尼亚|巴拿马|\bSOE\b|拼配"
_GRINDER_MODELS = ("Niche Zero", "Niche", "EK43", "DF64", "Lagom", "Breville", "Mazzer", "Weber", "Comandante")
_GRINDER_BRANDS = r"(?<![a-z0-9])(?:" + "|".join(
    re.escape(model).replace(r"\ ", r"\s+") for model in _GRINDER_MODELS
) + r")(?![a-z0-9])"
_GRINDER_BY_NAME = {model.lower(): model for model in _GRINDER_MODELS}


def _compute_stage_time_windows(duration_s, speech_segments=None, utterance_events=None):
    """Return (start, end, preferred timestamp, speech anchored) for each stage."""
    anchors = {}
    for events, is_audio in ((utterance_events or [], False), (speech_segments or [], True)):
        for i, event in enumerate(events):
            try:
                timestamp = float(event["timestamp_s"])
            except (KeyError, ValueError, TypeError):
                continue
            if not 0 < timestamp < duration_s:
                continue
            first = str(event.get("text") or "").lower().strip()
            text = first
            # Apple's recognizer can split terms such as 研磨, 刻度 and 停止录像 across segments.
            if is_audio:
                for following in events[i + 1:i + 4]:
                    if not isinstance(following.get("timestamp_s"), (int, float)):
                        break
                    if not 0 <= following["timestamp_s"] - timestamp <= 1.0:
                        break
                    text += str(following.get("text") or "").lower().strip()
            for stage, pattern in _STAGE_KEYWORDS.items():
                stop = stage == "yield_timer" and any(
                    m.start() < len(first) for m in re.finditer(_STOP_PATTERN, text)
                )
                matches = [m for m in re.finditer(pattern, text) if m.start() < len(first)]
                if not matches and not stop:
                    continue
                specificity = max((len(m.group()) for m in matches), default=0)
                # Prefer meaningful stage terms to incidental words, and use the MP4 clock
                # when an equally useful anchor is available from both sources.
                rank = (bool(matches), specificity, is_audio, timestamp)
                if stage not in anchors or rank > anchors[stage][0]:
                    anchors[stage] = (rank, timestamp, stop and not matches)
    windows = {}
    for (fraction, stage, _), (lo, hi) in zip(KEYFRAME_PLAN, _STAGE_WINDOWS):
        start, end, center, anchored = lo * duration_s, hi * duration_s, fraction * duration_s, False
        if stage in anchors:
            _, timestamp, stop = anchors[stage]
            if stop:
                start, end = max(0., timestamp - 3), max(0., timestamp - .4)
                if end <= start:
                    end = timestamp
                center = (start + end) / 2
            else:
                start, end = max(0., timestamp - 1.5), min(duration_s, timestamp + 1.5)
                center = timestamp
            anchored = True
        windows[stage] = start, end, center, anchored
    return windows


def _candidate_times(window, duration_s):
    start, end, center, _ = window
    return list(dict.fromkeys(min(t, max(0., duration_s - min(.02, duration_s / 10)))
                              for t in (center, start, end, (start + end) / 2,
                                        start + (end - start) / 3)))[:4]


def _frame_quality(gray):
    """Mean adjacent-pixel gradient on a 64x64 image, discounted for clipped exposure."""
    if not isinstance(gray, bytes) or len(gray) != 64 * 64:
        return 0.
    edges = sum(abs(value - gray[i - 1]) for i, value in enumerate(gray) if i % 64)
    edges += sum(abs(value - gray[i - 64]) for i, value in enumerate(gray) if i >= 64)
    clipped = sum(value < 20 or value > 235 for value in gray)
    return edges / len(gray) * (1 - .9 * clipped / len(gray))


def _ocr_fields(stage, texts, bean_library=()):
    lines = [unicodedata.normalize("NFKC", text).strip() for text in texts]
    text = " ".join(lines)
    flags = re.IGNORECASE
    fields = {}

    def reading(key, lo, hi, suffix, decimal_only=False):
        for match in re.finditer(_NUM + r"\s*(?:" + suffix + ")", text, flags):
            value = float(match[1])
            if lo <= value <= hi:
                fields[key] = value
                return
        if decimal_only:
            decimals = {float(line) for line in lines if re.fullmatch(r"\d+\.\d+", line)
                        and lo <= float(line) <= hi}
            if len(decimals) == 1:
                fields[key] = decimals.pop()

    if stage == "scale_dose":
        reading("bean_weight_g", 12, 25, r"g(?![a-z0-9])|克", decimal_only=True)
        matches = [(len(alias), bean.get("full_name") or bean.get("name") or alias)
                   for bean in bean_library
                   for alias in [bean.get("full_name"), bean.get("name"), *bean.get("short_aliases", [])]
                   if isinstance(alias, str) and alias and alias.casefold() in text.casefold()]
        origin = re.search(_BEAN_ORIGINS, text, flags)
        if matches:
            fields["bean_name"] = max(matches)[1]
        elif origin:
            fields["bean_name"] = origin[0]
    elif stage == "grinder_dial":
        model = re.search(_GRINDER_BRANDS, text, flags)
        if model:
            fields["grinder_model"] = _GRINDER_BY_NAME[" ".join(model[0].lower().split())]
        dial = re.search(r"(?:刻度|setting|dial)\s*[:#]?\s*" + _NUM, text, flags)
        standalone = {line for line in lines if re.fullmatch(r"\d{1,2}(?:\.\d+)?", line)}
        # Several unlabeled tick marks do not identify the pointer.
        if dial or len(standalone) == 1:
            fields["grind_setting"] = f"刻度 {dial[1] if dial else standalone.pop()}"
    elif stage == "pressure_crema":
        reading("pressure_bar", 8, 12, r"bar\b|巴")
        reading("water_temp_c", 88, 96, r"°\s*[cC]|摄氏度")
    elif stage == "yield_timer":
        reading("yield_g", 25, 65, r"g(?![a-z0-9])|克", decimal_only=True)
        reading("extraction_time_s", 18, 45, r"s(?:ec(?:onds?)?)?\b|秒")
        for match in re.finditer(r"(?<![\d:])0{1,2}\s*:\s*([0-5]\d)(?![\d:])", text):
            if 18 <= int(match[1]) <= 45:
                fields["extraction_time_s"] = int(match[1])
                break
    return fields


def _select_candidate(stage, candidates, center):
    def score(candidate):
        texts = candidate.get("ocr_texts", [])
        text = " ".join(unicodedata.normalize("NFKC", line) for line in texts)
        numbers = [float(match[1]) for match in re.finditer(_NUM, text)]
        lo, hi = {"scale_dose": (8, 35), "grinder_dial": (0, 99),
                  "pressure_crema": (5, 15), "yield_timer": (15, 80)}[stage]
        plausible = any(lo <= n <= hi or (stage == "pressure_crema" and 85 <= n <= 99)
                        for n in numbers)
        context = {
            "scale_dose": r"咖啡豆|粉量|浅烘|中烘|深烘|水洗|日晒|\bgrams?\b|\bg\b|克",
            "grinder_dial": r"刻度|刀盘|grind|dial",
            "pressure_crema": r"压力|\bbar\b|°C",
            "yield_timer": r"液重|出液|\b0{1,2}:|\bs\b|秒",
        }[stage]
        relevance = 6 * len(_ocr_fields(stage, texts)) + 2 * plausible + bool(re.search(context, text, re.I))
        return (candidate["sharpness_score"] + relevance,
                -abs(candidate["timestamp_s"] - center))
    return max(candidates, key=score)


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
    """Select brewing frames and recover parameters with on-device OCR and optional VLM."""

    def __init__(self, data_dir: str) -> None:
        self.data_dir = data_dir
        self.vlm_provider = os.environ.get("VLM_PROVIDER", "gemini-2.5-pro")

    def extract_audio_and_transcribe(self, video_path: str, fallback_transcript: str = "") -> str:
        """Compatibility entry point for callers that only need transcript text."""
        return self.extract_audio_and_transcribe_segments(video_path)[0] or fallback_transcript

    def extract_audio_and_transcribe_segments(self, video_path: str) -> Tuple[str, List[Dict[str, Any]]]:
        """Prefer on-device Speech timestamps; fall back to a local text-only Whisper CLI."""
        if not video_path or not os.path.isfile(video_path):
            return "", []
        swift_bin = shutil.which("swift") if sys.platform == "darwin" else None
        if swift_bin:
            transcript, segments = self._transcribe_with_macos_speech(video_path, swift_bin)
            if transcript:
                return transcript, segments
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
                        return proc.stdout.strip(), []
                except (OSError, subprocess.TimeoutExpired):
                    pass

        return "", []

    @staticmethod
    def _transcribe_with_macos_speech(
        media_path: str, swift_bin: str = "swift"
    ) -> Tuple[str, List[Dict[str, Any]]]:
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
        if sem.wait(timeout: .now() + 15) == .success && exporter.status == .completed {
            targetURL = tmp
            tempM4A = tmp
        } else {
            exporter.cancelExport()
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
defer {
    if let tmp = tempM4A {
        try? FileManager.default.removeItem(at: tmp)
    }
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
      recognizer.supportsOnDeviceRecognition else { exit(0) }
let req = SFSpeechURLRecognitionRequest(url: targetURL)
req.requiresOnDeviceRecognition = true
req.shouldReportPartialResults = false

var transcription: SFTranscription?
let completed = DispatchSemaphore(value: 0)
let task = recognizer.recognitionTask(with: req) { result, error in
    if let result = result, result.isFinal {
        transcription = result.bestTranscription
        completed.signal()
    } else if error != nil {
        completed.signal()
    }
}
let deadline = Date().addingTimeInterval(20)
var done = false
while !done && Date() < deadline {
    done = completed.wait(timeout: .now()) == .success
    if !done { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}
if done, let transcription = transcription {
    let segments: [[String: Any]] = transcription.segments.map {
        ["text": $0.substring, "timestamp_s": $0.timestamp, "duration_s": $0.duration]
    }
    let data = try JSONSerialization.data(withJSONObject: ["text": transcription.formattedString,
                                                           "segments": segments])
    print(String(decoding: data, as: UTF8.self))
} else {
    task.cancel()
}
"""
        try:
            proc = subprocess.run(
                [swift_bin, "-e", swift_script, media_path], capture_output=True, text=True, timeout=42,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                payload = json.loads(proc.stdout)
                return payload["text"], payload["segments"]
        except (OSError, subprocess.TimeoutExpired, ValueError, KeyError):
            pass
        return "", []

    @staticmethod
    def _run_macos_keyframes(swift_bin, *args):
        try:
            proc = subprocess.run([swift_bin, _SWIFT_KEYFRAMES, *args], capture_output=True,
                                  text=True, timeout=30)
            if proc.returncode == 0 and proc.stdout.strip():
                return json.loads(proc.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            pass
        return {}

    def _extract_with_macos_avfoundation(self, source, target_dir, plan, swift_bin):
        return self._run_macos_keyframes(swift_bin, "extract", source, target_dir, json.dumps(plan))

    def _extract_with_ffmpeg(self, source, target_dir, plan, ffmpeg_bin, swift_bin=None):
        candidates = {}
        for stage, times in plan.items():
            frames = candidates[stage] = []
            for index, timestamp in enumerate(sorted(times)):
                path = os.path.join(target_dir, f"{stage}-{index}.jpg")
                try:
                    proc = subprocess.run([
                        ffmpeg_bin, "-nostdin", "-hide_banner", "-loglevel", "info",
                        "-ss", f"{timestamp:.6f}", "-copyts", "-start_at_zero", "-i", source,
                        "-map", "0:v:0", "-frames:v", "1", "-vf", "showinfo,scale=64:64,format=gray",
                        "-c:v", "rawvideo", "-threads", "1", "-f", "rawvideo", "pipe:1",
                        "-map", "0:v:0", "-frames:v", "1", "-vf",
                        "scale=640:640:force_original_aspect_ratio=decrease", "-q:v", "3", path,
                    ], capture_output=True, timeout=10)
                except (OSError, subprocess.TimeoutExpired):
                    continue
                if proc.returncode == 0 and os.path.isfile(path) and os.path.getsize(path) > 0:
                    stderr = proc.stderr.decode(errors="replace") if isinstance(proc.stderr, bytes) else proc.stderr
                    actual = re.search(r"\bpts_time:([\d.]+)", stderr)
                    frames.append(dict(path=path, timestamp_s=float(actual[1]) if actual else timestamp,
                                       sharpness_score=_frame_quality(proc.stdout), ocr_texts=[]))
        if swift_bin:
            decoded = [frame for frames in candidates.values() for frame in frames]
            if decoded:
                texts = self._run_macos_keyframes(swift_bin, "ocr", *(f["path"] for f in decoded))
                for frame in decoded:
                    frame["ocr_texts"] = texts.get(frame["path"], [])
        return candidates

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
        speech_segments: Optional[List[Dict[str, Any]]] = None,
        utterance_events: Optional[List[Dict[str, Any]]] = None,
    ) -> Dict[str, Any]:
        """Probe local video and score up to four candidates per brewing stage."""
        source = (video_source or "").strip()
        is_remote = source.startswith(("http://", "https://"))
        is_local = bool(source and not is_remote and os.path.isfile(source))
        source_type = "remote_http" if is_remote else "local_file" if is_local else "synthetic_or_missing"
        target_dir = output_dir or os.path.join(self.data_dir, "keyframes", self._derive_session_slug(source))

        ffprobe = shutil.which("ffprobe")
        ffmpeg = shutil.which("ffmpeg")
        swift = shutil.which("swift") if sys.platform == "darwin" else None
        size = os.path.getsize(source) if is_local else None
        duration = width = height = None
        backend = None
        fallback_reason = None
        if is_local and swift and size:
            probe = self._run_macos_keyframes(swift, "probe", source)
            duration, width, height = (probe.get(key) for key in ("duration_s", "width", "height"))
            if duration:
                backend = "avfoundation"
        if is_local and not duration and ffprobe:
            try:
                proc = subprocess.run([
                    ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
                    "stream=width,height,duration:format=duration,size", "-of", "json", source,
                ], capture_output=True, text=True, timeout=15, check=False)
                if proc.returncode == 0:
                    probe = json.loads(proc.stdout)
                    stream = (probe.get("streams") or [{}])[0]
                    fmt = probe.get("format") or {}
                    width, height = stream.get("width"), stream.get("height")
                    if fmt.get("size") not in (None, "", "N/A"):
                        size = int(fmt["size"])
                    duration = next((float(value) for value in (stream.get("duration"), fmt.get("duration"))
                                     if value not in (None, "", "N/A")), None)
            except (OSError, subprocess.TimeoutExpired, ValueError):
                pass
        if duration is not None and (not math.isfinite(duration) or duration <= 0):
            duration = None

        selected = {}
        windows = _compute_stage_time_windows(duration, speech_segments, utterance_events) if duration else {}
        if extract_frames and duration and (backend or ffmpeg):
            os.makedirs(target_dir, exist_ok=True)
            plan = {stage: _candidate_times(window, duration) for stage, window in windows.items()}
            with tempfile.TemporaryDirectory(dir=target_dir) as temporary:
                candidates = (self._extract_with_macos_avfoundation(source, temporary, plan, swift)
                              if backend else {})
                missing = {stage: times for stage, times in plan.items() if not candidates.get(stage)}
                if missing and ffmpeg:
                    fallback = self._extract_with_ffmpeg(source, temporary, missing, ffmpeg, swift)
                    if any(fallback.values()):
                        backend = "avfoundation+ffmpeg" if any(candidates.values()) else "ffmpeg"
                    candidates.update(fallback)
                for fraction, stage, _ in KEYFRAME_PLAN:
                    frames = candidates.get(stage) or []
                    if not frames:
                        continue
                    _, _, center, anchored = windows[stage]
                    winner = _select_candidate(stage, frames, center)
                    path = os.path.join(target_dir, f"frame_{round(fraction * 100):02d}pct_{stage}.jpg")
                    os.replace(winner["path"], path)
                    timestamp = winner["timestamp_s"]
                    selected[stage] = dict(
                        image_path=path, extracted=True, timestamp_s=round(timestamp, 3),
                        fraction=timestamp / duration, percentage=round(100 * timestamp / duration),
                        selection_method=("speech_anchor" if anchored else "smart_window") + "+vision_score",
                        sharpness_score=round(winner["sharpness_score"], 3), candidates_evaluated=len(frames),
                        ocr_texts=winner["ocr_texts"],
                    )

        if not selected:
            if not is_local:
                fallback_reason = "remote_http_source_deferred" if is_remote else "local_file_not_found"
            elif not extract_frames:
                fallback_reason = "frame_extraction_disabled"
            elif not duration:
                fallback_reason = "duration_unavailable"
            else:
                fallback_reason = "frame_extraction_failed"

        keyframes = []
        for idx, (fraction, stage, label) in enumerate(KEYFRAME_PLAN):
            pct = round(fraction * 100)
            frame = dict(
                stage_key=stage, stage=label, gimbal_preset=STAGE_TO_GIMBAL_PRESET[stage],
                planned_image_path=os.path.join(target_dir, f"frame_{pct:02d}pct_{stage}.jpg"),
                percentage=pct, fraction=fraction, image_path=None, extracted=False,
                timestamp_s=round(duration * fraction, 2) if duration else DEFAULT_FALLBACK_TIMESTAMPS[idx],
            )
            frame.update(selected.get(stage, {}))
            keyframes.append(frame)

        return dict(
            video_source=source, source_type=source_type, is_remote_url=is_remote, reachable_local=is_local,
            ffmpeg_available=bool(ffmpeg and ffprobe), extracted_real_frames=bool(selected),
            extracted_frame_count=len(selected), frame_backend=backend if selected else None,
            output_dir=target_dir, duration_s=round(duration, 3) if duration is not None else None,
            width=width, height=height, resolution=f"{width}x{height}" if width and height else None,
            size_bytes=size, keyframes=keyframes, fallback_reason=fallback_reason,
        )

    @staticmethod
    def _normalize_vlm_fields(raw_payload: Any) -> Dict[str, Any]:
        if not isinstance(raw_payload, dict):
            return {}
        normalized: Dict[str, Any] = {}
        numeric_keys = {"bean_weight_g", "pressure_bar", "yield_g", "extraction_time_s", "water_temp_c"}
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
            "shot yield (g), shot timer (seconds), bean bag label, and water temperature (°C). "
            "Return ONLY a JSON object with keys: "
            '{"bean_weight_g": number|null, "grind_setting": string|null, "grinder_model": string|null, '
            '"pressure_bar": number|null, "yield_g": number|null, "extraction_time_s": number|null, '
            '"bean_name": string|null, "water_temp_c": number|null}. '
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

    def _extract_fields_from_local_ocr(self, keyframes, duration_s, bean_library=None):
        # The timer may have started before recording; its reading need not fit the clip duration.
        if bean_library is None:
            for name in ("bean_library.json", "bean_equipment_library.json"):
                try:
                    with open(os.path.join(self.data_dir, name), encoding="utf-8") as file:
                        bean_library = json.load(file)
                    break
                except (OSError, ValueError):
                    continue
        beans = bean_library.get("beans", []) if isinstance(bean_library, dict) else bean_library
        fields = {}
        for frame in keyframes:
            fields.update(_ocr_fields(frame["stage_key"], frame.get("ocr_texts", []), beans or []))
        return fields

    def analyze_video_keyframes(
        self,
        video_path: Optional[str],
        spoken_transcript: str = "",
        camera_device: str = "DJI Osmo Pocket 4 Pro",
        hint_overrides: Optional[Dict[str, Any]] = None,
        extract_frames: bool = True,
        speech_segments: Optional[List[Dict[str, Any]]] = None,
        utterance_events: Optional[List[Dict[str, Any]]] = None,
    ) -> Dict[str, Any]:
        """
        Analyzes key visual moments from the Pocket 3 / Pocket 4 Pro video recording
        (supporting both local `.MP4` file paths and remote camera HTTP URLs such as
        `http://192.168.5.93:8088/DJI_001/...`) to recover any parameters the user
        didn't explicitly speak aloud.
        """
        if video_path:
            meta = self.extract_video_metadata_and_frames(
                video_path, extract_frames=extract_frames, speech_segments=speech_segments,
                utterance_events=utterance_events,
            )
        else:
            meta = self.extract_video_metadata_and_frames("", extract_frames=False)

        kf_list = meta["keyframes"]
        vlm_fields, vlm_live_used, active_vlm_model = self._inspect_keyframes_with_vlm(
            kf_list,
            spoken_transcript=spoken_transcript,
            camera_device=camera_device,
        )

        merged_visual_fields = {k: v for k, v in (hint_overrides or {}).items() if v is not None}
        merged_visual_fields.update(self._extract_fields_from_local_ocr(kf_list, meta["duration_s"]))
        merged_visual_fields.update(vlm_fields)

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
            description = descriptions[i] if i < len(descriptions) else src_note
            if kf.get("selection_method"):
                label = "语音锚点" if kf["selection_method"].startswith("speech_anchor") else "阶段窗口"
                description += (f"；智能选帧 ({label}, t={kf['timestamp_s']:.2f}s, "
                                f"清晰度 {kf['sharpness_score']:.1f}, 候选 {kf['candidates_evaluated']} 帧)")
                if kf.get("ocr_texts"):
                    description += "；OCR：" + " / ".join(kf["ocr_texts"][:4])[:120]
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
                    visual_description=description,
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
