"""
Device-Agnostic Coffee Ingestion, Recognition & Report Pipeline.

Completely decouples:
1. Capture / Input Sources (DJI Pocket 3/4P, iPhone, iPad, Mac, Web upload, Audio memos, Text)
2. Media Recognition (`MultimodalVisionEngine`: audio ASR + video keyframe OCR/VLM)
3. Report & Equipment Generation (`analyzer` + `SessionContextCompactor`)
4. Bean Library & Equipment Profile Management (`BeanAndEquipmentManager`)
5. Record Persistence (`CoffeeStore`) & Notifications (`NotificationManager`)
"""

from datetime import datetime
import os
from typing import Any, Dict, List, Optional

from core.analyzer import (
    enrich_barista_analysis,
    extract_equipment_items_from_transcript,
    extract_parameters_from_transcript,
    is_equipment_introduction,
    relabel_keyframes_for_equipment_profile,
)
from core.bean_equipment_store import BeanAndEquipmentManager
from core.context_engine import SessionContextCompactor
from core.models import CoffeeRecord
from core.multimodal_vision import MultimodalVisionEngine, detect_media_kind
from core.notifier import NotificationManager
from core.registry import global_event_bus
from core.store import CoffeeStore


SOURCE_DEVICE_LABELS: Dict[str, str] = {
    "iphone": "iPhone 手机录制",
    "ipad": "iPad 平板录制",
    "dji_pocket": "DJI Osmo Pocket",
    "mac": "Mac 桌面录制",
    "web_upload": "网页端导入",
    "audio_note": "语音备忘录",
    "manual_text": "手动文字/语音输入",
}


class CoffeeIngestionPipeline:
    """Independent, device-agnostic orchestrator for recognition, report generation, and equipment ingestion."""

    def __init__(
        self,
        store: CoffeeStore,
        vision_engine: MultimodalVisionEngine,
        bean_manager: BeanAndEquipmentManager,
        notifier: Optional[NotificationManager] = None,
        compactor: Optional[SessionContextCompactor] = None,
    ) -> None:
        self.store = store
        self.vision_engine = vision_engine
        self.bean_manager = bean_manager
        self.notifier = notifier
        self.compactor = compactor or SessionContextCompactor()

    def recognize_media(
        self,
        media_path: Optional[str] = None,
        spoken_transcript: str = "",
        source_device: str = "通用录制设备",
        hint_overrides: Optional[Dict[str, Any]] = None,
        extract_frames: bool = True,
        utterance_events: Optional[List[Dict[str, Any]]] = None,
        speech_segments: Optional[List[Dict[str, Any]]] = None,
        transcribe_audio: bool = True,
    ) -> Dict[str, Any]:
        """Run standalone video/audio recognition without generating or persisting a report."""
        return self.vision_engine.recognize_media(
            media_path=media_path,
            spoken_transcript=spoken_transcript,
            source_device=source_device,
            hint_overrides=hint_overrides,
            extract_frames=extract_frames,
            utterance_events=utterance_events,
            speech_segments=speech_segments,
            transcribe_audio=transcribe_audio,
        )

    def generate_report(
        self,
        transcript: str,
        *,
        source_device: str = "通用录制设备",
        source_type: str = "web_upload",
        media_kind: Optional[str] = None,
        video_path: Optional[str] = None,
        media_url: Optional[str] = None,
        utterance_events: Optional[List[Dict[str, Any]]] = None,
        visual_fields: Optional[Dict[str, Any]] = None,
        frame_observations: Optional[List[Dict[str, Any]]] = None,
        session_id: Optional[str] = None,
        record_intent: str = "auto",  # "auto" | "brew_report" | "equipment_profile"
        save: bool = True,
        notify: bool = True,
        has_meaningful_speech: Optional[bool] = None,
    ) -> Dict[str, Any]:
        """
        Standalone report / equipment-profile generation module.
        Can be called directly from recognized outputs, pasted transcripts, or external integrations.
        """
        full_transcript = (transcript or "").strip()
        resolved_media_kind = media_kind or detect_media_kind(video_path or media_url)
        resolved_device = (source_device or "").strip() or SOURCE_DEVICE_LABELS.get(source_type, "通用录制设备")
        sess_id = session_id or f"ingest-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

        utterances = list(utterance_events or [])
        if not utterances and full_transcript:
            utterances = [{
                "text": full_transcript,
                "source": source_type,
                "timestamp": datetime.now().strftime("%H:%M:%S"),
            }]

        compacted = self.compactor.compact_utterances(sess_id, utterances, camera_device=resolved_device)
        spoken_canonical = dict(compacted.canonical_parameters)

        v_fields = dict(visual_fields or {})
        visual_provenance = self.compactor.merge_visual_parameters(
            compacted,
            v_fields,
            evidence_source=video_path or media_url or source_type,
        )

        lib_data = self.bean_manager.load_all()
        matched_bean = self.bean_manager.match_bean_by_text(full_transcript)

        # Gatekeeper: reject unrelated non-coffee content so accidental uploads/notes never pollute records
        coffee_keywords = (
            "咖啡", "浓缩", "意式", "美式", "拿铁", "冷萃", "冰滴", "手冲", "萃取", "预浸泡",
            "粉液比", "粉量", "粉重", "液重", "出液", "称豆", "磨豆", "研磨", "刻度", "压粉",
            "布粉", "手柄", "豆仓", "烘焙", "浅烘", "中烘", "深烘", "水洗", "日晒", "厌氧",
            "油脂", "虎斑", "耶加", "瑰夏", "花魁", "西达摩", "曼特宁", "soe", "espresso",
            "latte", "cold brew", "pour over", "barista", "crema", "grinder", "portafilter",
            "格米莱", "3828", "铂富", "德龙", "niche", "df64", "ek43", "breville", "acaia",
            "轰炸机", "摩卡壶", "法压壶", "爱乐压", "dirty",
        )
        lowered_text = full_transcript.lower()
        has_visual_signal = any(val is not None and str(val).strip() != "" for val in v_fields.values())
        has_keyword_signal = any(kw in lowered_text for kw in coffee_keywords)
        if not matched_bean and not has_visual_signal and not has_keyword_signal:
            probe = extract_parameters_from_transcript(
                transcript=full_transcript,
                camera_device=resolved_device,
                video_path=video_path,
                visual_Overrides=None,
            )
            has_extracted_signal = any([
                probe.bean_name,
                probe.bean_roast,
                probe.bean_weight_g is not None,
                probe.grind_setting,
                probe.grinder_type,
                probe.grinder_model,
                probe.brew_method,
                probe.yield_g is not None,
                probe.extraction_time_s is not None,
                probe.pressure_bar is not None,
                probe.water_temp_c is not None,
            ])
            if not has_extracted_signal:
                reason = "未检测到咖啡制作或器具相关内容，已自动拦截，未写入档案库。"
                rejected = CoffeeRecord(
                    camera_device=resolved_device,
                    source_type=source_type,
                    media_kind=resolved_media_kind,
                    video_path=video_path,
                    media_url=media_url,
                    transcript=full_transcript,
                    extraction_diagnosis=reason,
                    record_type="brew_report",
                    status="rejected",
                )
                return {
                    "ok": True,
                    "saved": False,
                    "rejected_as_non_coffee": True,
                    "rejection_reason": reason,
                    "record": rejected.to_dict(),
                    "record_obj": rejected,
                    "record_type": rejected.record_type,
                    "source_type": source_type,
                    "source_device": resolved_device,
                    "media_kind": resolved_media_kind,
                    "compacted_context": compacted.to_dict(),
                    "compacted_obj": compacted,
                    "visual_provenance": visual_provenance,
                    "equipment_profile_updated": None,
                    "bean_inventory": None,
                    "notification": {},
                }

        overrides: Dict[str, Any] = dict(v_fields)
        overrides.update(spoken_canonical)
        if matched_bean:
            overrides["_bean_library_match"] = matched_bean
        if lib_data.get("equipment"):
            overrides["_equipment_defaults"] = lib_data["equipment"]

        record = extract_parameters_from_transcript(
            transcript=full_transcript,
            camera_device=resolved_device,
            video_path=video_path,
            visual_Overrides=overrides,
        )
        record.source_type = source_type
        record.media_kind = resolved_media_kind

        # Ensure canonical spoken values (e.g. from self-corrections) take precedence
        for k, v in spoken_canonical.items():
            if v is not None and hasattr(record, k):
                setattr(record, k, v)

        # Merge visual/OCR/VLM recovered fields for any parameter missing from speech
        for k, prov in visual_provenance.items():
            rec_val = prov.get("value")
            if rec_val is not None and spoken_canonical.get(k) is None and hasattr(record, k):
                setattr(record, k, rec_val)
                if k == "grinder_model" and spoken_canonical.get("grinder_type") is None:
                    if any(tok in str(rec_val) for tok in ("内置", "自带", "Breville", "铂富", "德龙", "格米莱")):
                        record.grinder_type = "咖啡机自带磨豆机"
                    elif not record.grinder_type:
                        record.grinder_type = "额外独立磨豆机"

        if matched_bean and matched_bean.get("full_name"):
            record.bean_name = matched_bean["full_name"]

        # Respect explicit user intent ("equipment_profile" or "brew_report") when provided
        intent = (record_intent or "auto").strip().lower()
        if intent == "equipment_profile":
            record.record_type = "equipment_profile"
            if not record.equipment_items:
                record.equipment_items = extract_equipment_items_from_transcript(full_transcript)
            if not record.brew_method:
                record.brew_method = "常驻设备与器具档案补充"
            if not record.bean_name:
                record.bean_name = f"{record.grinder_model or '居家咖啡机'} · 全套器具建档"
        elif intent == "brew_report":
            record.record_type = "brew_report"
        else:
            # Auto classification already ran inside extract_parameters_from_transcript,
            # re-check in case merged visual/canonical fields affected it.
            if record.record_type != "equipment_profile" and is_equipment_introduction(full_transcript, record):
                record.record_type = "equipment_profile"
                record.equipment_items = extract_equipment_items_from_transcript(full_transcript)

        keyframes = list(frame_observations or [])
        if record.record_type == "equipment_profile" and keyframes:
            keyframes = relabel_keyframes_for_equipment_profile(keyframes, record.equipment_items)

        record.keyframes = keyframes
        record.media_url = media_url
        record.compute_derived_metrics()
        enrich_barista_analysis(record)

        # Persist equipment profile if classified as equipment_profile
        equipment_profile_updated: Optional[Dict[str, Any]] = None
        if save and record.record_type == "equipment_profile":
            inferred_machine = next(
                (
                    str(it.get("name"))
                    for it in (record.equipment_items or [])
                    if isinstance(it, dict)
                    and it.get("name")
                    and (
                        "咖啡机" in str(it.get("category") or "")
                        or "machine" in str(it.get("id") or "").lower()
                        or "gemilai" in str(it.get("id") or "").lower()
                    )
                ),
                record.grinder_model if record.grinder_type == "咖啡机自带磨豆机" else None,
            )
            equipment_profile_updated = self.bean_manager.update_equipment_from_intro(
                equipment_items=record.equipment_items,
                grinder_type=record.grinder_type,
                grinder_model=record.grinder_model,
                espresso_machine=inferred_machine,
                keyframes=record.keyframes,
            )

        has_any_captured_info = bool(
            record.record_type == "equipment_profile"
            or record.bean_name
            or record.bean_weight_g is not None
            or record.yield_g is not None
            or record.extraction_time_s is not None
            or record.pressure_bar is not None
            or record.grind_setting
            or (has_meaningful_speech if has_meaningful_speech is not None else bool(full_transcript))
        )

        if save and has_any_captured_info:
            self.store.save_record(record)

        # Auto-deduct consumed bean weight for actual brews
        bean_inventory: Optional[Dict[str, Any]] = None
        if (
            save
            and record.record_type != "equipment_profile"
            and record.bean_weight_g is not None
            and float(record.bean_weight_g) > 0
            and record.bean_name
        ):
            bean_inventory = self.bean_manager.deduct_bean_dose(
                record.bean_name, float(record.bean_weight_g)
            )

        notif: Dict[str, Any] = {}
        if save and notify and has_any_captured_info and self.notifier is not None:
            notif = self.notifier.notify_brew_record(record)

        if save:
            global_event_bus.publish(
                "pipeline.completed",
                {
                    "record_id": record.id,
                    "record_type": record.record_type,
                    "source_type": source_type,
                    "source_device": resolved_device,
                    "media_kind": resolved_media_kind,
                },
            )

        return {
            "ok": True,
            "saved": bool(save and has_any_captured_info),
            "record": record.to_dict(),
            "record_obj": record,
            "record_type": record.record_type,
            "source_type": source_type,
            "source_device": resolved_device,
            "media_kind": resolved_media_kind,
            "compacted_context": compacted.to_dict(),
            "compacted_obj": compacted,
            "visual_provenance": visual_provenance,
            "equipment_profile_updated": equipment_profile_updated,
            "bean_inventory": bean_inventory,
            "notification": notif,
        }

    def ingest_media(
        self,
        *,
        media_path: Optional[str] = None,
        media_url: Optional[str] = None,
        transcript: str = "",
        source_device: str = "",
        source_type: str = "web_upload",
        record_intent: str = "auto",
        hint_overrides: Optional[Dict[str, Any]] = None,
        utterance_events: Optional[List[Dict[str, Any]]] = None,
        extract_frames: bool = True,
        save: bool = True,
        notify: bool = True,
    ) -> Dict[str, Any]:
        """
        End-to-end device-agnostic media ingestion:
        1. Recognize audio speech + (if video) extract keyframes & OCR/VLM.
        2. Generate brew report or equipment profile, update bean/equipment store, and notify.
        """
        resolved_device = (source_device or "").strip() or SOURCE_DEVICE_LABELS.get(source_type, "通用录制设备")
        recognition = self.recognize_media(
            media_path=media_path or media_url,
            spoken_transcript=transcript,
            source_device=resolved_device,
            hint_overrides=hint_overrides,
            extract_frames=extract_frames,
            utterance_events=utterance_events,
        )

        # Build utterance events preserving recognized audio + any manual notes
        events = list(utterance_events or [])
        if recognition["audio_transcript"]:
            events = [
                {
                    "text": recognition["audio_transcript"],
                    "source": f"{source_type}_audio",
                    "timestamp": datetime.now().strftime("%H:%M:%S"),
                },
                *events,
            ]
        if transcript.strip() and not utterance_events:
            events.append({
                "text": transcript.strip(),
                "source": f"{source_type}_note",
                "timestamp": datetime.now().strftime("%H:%M:%S"),
            })

        report_res = self.generate_report(
            transcript=recognition["transcript"],
            source_device=resolved_device,
            source_type=source_type,
            media_kind=recognition["media_kind"],
            video_path=media_path or media_url,
            media_url=media_url,
            utterance_events=events,
            visual_fields=recognition["visual_fields"],
            frame_observations=recognition["frame_observations"],
            record_intent=record_intent,
            save=save,
            notify=notify,
        )
        return {
            "ok": True,
            "recognition": {
                "media_kind": recognition["media_kind"],
                "audio_transcript": recognition["audio_transcript"],
                "transcript": recognition["transcript"],
                "speech_segments_count": len(recognition["speech_segments"]),
                "visual_fields": recognition["visual_fields"],
                "keyframes_count": len(recognition["frame_observations"]),
            },
            "vision_analysis": recognition["vision_analysis"],
            "visual_provenance": report_res["visual_provenance"],
            "compacted_context": report_res["compacted_context"],
            "record": report_res["record"],
            "record_type": report_res["record_type"],
            "saved": report_res["saved"],
            "rejected_as_non_coffee": bool(report_res.get("rejected_as_non_coffee", False)),
            "rejection_reason": report_res.get("rejection_reason"),
            "equipment_profile_updated": report_res["equipment_profile_updated"],
            "bean_inventory": report_res["bean_inventory"],
            "notification": report_res["notification"],
        }
