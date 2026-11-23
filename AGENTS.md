# Pocket Coffee Log — Project Guide (AGENTS.md)

## Quick File Map
- `server/app.py`: Local HTTP/API server (`:8788`), serves `static/` via `SimpleHTTPRequestHandler`.
- `core/models.py`: `CoffeeRecord` dataclass (`record_type`: `"brew_report"` | `"equipment_profile"`, `equipment_items`).
- `core/analyzer.py`: Transcript parameter extraction, equipment-intro classifier (`is_equipment_introduction`, `extract_equipment_items_from_transcript`, `relabel_keyframes_for_equipment_profile`), barista diagnosis & social copy generation.
- `core/bean_equipment_store.py`: Persistent bean inventory & permanent equipment profile (`update_equipment_from_intro`, `deduct_bean_dose`).
- `core/multimodal_vision.py`: Standalone video/audio recognition module (`recognize_media`, keyframe extraction via `core/macos_keyframes.swift`, offline OCR & audio transcription).
- `core/pipeline.py`: Device-agnostic `CoffeeIngestionPipeline` orchestrating recognition → report/equipment generation → bean/equipment store → notifications.
- `core/media_upload.py`: Streaming `multipart/form-data` upload parser & media MIME helper for iPhone/iPad/Mac/Web uploads.
- `core/camera_sta_bridge.py`: Optional DJI Pocket 3/4 Pro USB/ADB/Wi-Fi STA capture bridge (`data/pocket_sta_agent.sh`).
- `core/store.py` / `core/notifier.py` / `core/context_engine.py`: JSON record store, Bark/WeChat notifications, context snapshot.
- `daemon/voice_session.py`: Optional DJI camera mic wake/stop adapter delegating report/equipment generation to `CoffeeIngestionPipeline`.
- `static/index.html`: App shell markup (<400 lines).
- `static/css/styles.css`: All UI styles.
- `static/js/app.js`: Core state, polling, voice controls, report/radar/comparison rendering, accessible toast & clipboard helper.
- `static/js/ingest.js`: Multi-device video/audio upload & standalone recognition preview module (iPhone / iPad / Mac / Web).
- `static/js/equipment.js`: Bean inventory, label scanning, permanent equipment profile editor.
- `static/js/camera.js`: Camera STA/USB status, gimbal/shutter/media pull, notifications tab.
- `static/js/share.js`: 3:4 canvas poster export, clipboard image copy, Web Share API, multi-platform quick share (Xiaohongshu, WeChat, Weibo/Jike, Markdown/Notion).

## Commands
- Run tests: `make test` (or `python3 -m unittest discover -s tests -p "test_*.py" -v`)
- Run server: `make server` (`PORT=8788 python3 server/app.py`)
- Refresh snapshot: `make snapshot`

## Runtime Deployment
- Live runtime directory: `/Users/zhengjiaxin/Library/Application Support/Pocket Coffee Log/runtime`
- Data files: `data/coffee_records.json`, `data/bean_equipment_library.json`, `data/camera_sta_state.json`
- Always keep `static/` modular (CSS in `static/css/`, JS in `static/js/`) so future edits touch small files only.
