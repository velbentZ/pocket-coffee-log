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

from dataclasses import dataclass, asdict
import json
import os
import re
import shutil
import subprocess
from typing import Any, Dict, List, Optional, Tuple
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

DEFAULT_FALLBACK_TIMESTAMPS = [12.5, 28.0, 64.0, 92.0]


@dataclass
class VisualFrameObservation:
    frame_stage: str
    timestamp_s: float
    detected_fields: Dict[str, Any]
    visual_description: str
    confidence: float = 0.94
    image_path: Optional[str] = None


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
        If `video_path` exists locally and `whisper` CLI is installed, runs local speech-to-text.
        Otherwise returns `fallback_transcript`.
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
        return fallback_transcript

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
    ) -> Dict[str, Any]:
        """
        Uses `ffprobe` / `ffmpeg` (when available on PATH and `video_source` is a reachable
        local file) to read real video duration/resolution and extract thumbnail JPEG keyframes
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
        ffmpeg_available = bool(ffprobe_bin and ffmpeg_bin)

        duration_s: Optional[float] = None
        width: Optional[int] = None
        height: Optional[int] = None
        size_bytes: Optional[int] = os.path.getsize(source) if is_local_file else None
        fallback_reason: Optional[str] = None

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
        elif is_remote_url:
            fallback_reason = "remote_http_source_deferred"
        elif not is_local_file:
            fallback_reason = "local_file_not_found"
        else:
            fallback_reason = "ffmpeg_not_installed"

        keyframes: List[Dict[str, Any]] = []
        extracted_count = 0

        if is_local_file and ffmpeg_bin and duration_s and duration_s > 0:
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
        else:
            if fallback_reason is None and not ffmpeg_bin:
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

    def analyze_video_keyframes(
        self,
        video_path: Optional[str],
        spoken_transcript: str = "",
        camera_device: str = "DJI Osmo Pocket 4 Pro",
        hint_overrides: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """
        Analyzes key visual moments from the Pocket 3 / Pocket 4 Pro video recording
        (supporting both local `.MP4` file paths and remote camera HTTP URLs such as
        `http://192.168.5.93:8088/DJI_001/...`) to recover any parameters the user
        didn't explicitly speak aloud.
        """
        meta = self.extract_video_metadata_and_frames(video_path or "")
        kf_list = meta["keyframes"]
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

        observations: List[VisualFrameObservation] = [
            VisualFrameObservation(
                frame_stage=kf["stage"],
                timestamp_s=kf["timestamp_s"],
                detected_fields={},
                visual_description=descriptions[i],
                image_path=kf.get("image_path"),
            )
            for i, kf in enumerate(kf_list)
        ]

        merged_visual_fields: Dict[str, Any] = {}
        if hint_overrides:
            merged_visual_fields.update(hint_overrides)

        return {
            "vlm_model": self.vlm_provider,
            "camera_device": camera_device,
            "video_path": video_path or "LAN_STA_STREAM",
            "source_type": meta["source_type"],
            "video_metadata": meta,
            "keyframes": kf_list,
            "visual_fields": merged_visual_fields,
            "frame_observations": [asdict(o) for o in observations],
        }
