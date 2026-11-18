# 🧠 CONTEXT_SNAPSHOT · 上下文无损压缩与持续迭代锚点

> **设计目标**：当对话上下文发生压缩（Context Compaction）或开启新一轮迭代时，读取本文件与 `.context/memory_snapshot.json` 即可 **100% 零信息丢失** 恢复全部架构约束、硬件协议细节、模块契约与迭代进度。

- **Schema 版本**: `3.0.0`
- **GitHub 仓库**: `https://github.com/velbentZ/pocket-coffee-log`
- **本地项目路径**: `/Users/zhengjiaxin/Documents/pocket-coffee-log`
- **默认服务端口**: `8788`

## 1. 核心不可违背约束 (Hard Invariants)
1. 8 Required Brew Fields: bean_name, bean_weight_g, grind_setting, grinder_type (independent vs built-in), grinder_model, brew_method (Espresso vs Cold Brew), yield_g, extraction_time_s, pressure_bar.
2. Single-Camera Active Rotation: User rotates between Pocket 3 and Pocket 4 Pro (one active camera per brew); system automatically binds whichever camera triggers or is selected.
3. Verified Camera STA Mode (eagle4_hg224): Live OsmoPocket4P-ANHXP5J0022DTW root ADB (2ca3:0020) writes 'load' to PCIe Wi-Fi sysfs to bring up wlan0, runs wpa_supplicant + busybox udhcpc for Home LAN STA 192.168.5.93, and pairs with DUML v1 [07:47] STA / [02:02] Shutter / [04:14] OsmoDesk Gimbal presets.
4. On-Camera Internal Daemon: /data/pocket-coffee/pocket_sta_agent.sh (persisted on writable /data partition; /system and /vendor are read-only ext4) keeps wpa_supplicant alive, exposes /mnt/media_rw/emulated/DCIM/DJI_001 via BusyBox httpd on :8088, sends verified source-IP heartbeats to /api/camera/heartbeat, and webhooks /api/camera/webhook on MP4 completion.
5. Multimodal AI & FFmpeg 4-Stage Keyframe Pipeline: Local Whisper speech transcription + FFmpeg 4-stage keyframe extraction (15% scale_dose, 35% grinder_dial, 70% pressure_crema, 90% yield_timer) + optional live Gemini/OpenAI VLM inspection recovering unspoken parameters with source='video_frame_ocr' provenance.
6. Beanconqueror Inventory, Label Scanner & Visualizer Loop: Speaking bean shorthand ('今天用花魁') auto-fills origin/process/roast & deducts dose weight with freshness lifecycle tracking (Degassing / Peak Window / Aging); supports AI bag label parsing and Visualizer side-by-side dual-shot comparison.
7. Lossless Context Compaction: SessionContextCompactor preserves provenance (voice_utterance / video_frame_ocr / mobile_supplement) + revision history for self-corrections while compressing raw transcripts.

## 2. 模块化架构契约 (Module Contracts)
| 模块路径 | 职责边界与接口契约 |
| :--- | :--- |
| `core/models.py` | Data contracts (CoffeeRecord with keyframes & media_url, FlavorProfile, REQUIRED_BREW_FIELDS) |
| `core/registry.py` | Decoupled EventBus & ModuleRegistry for pluggable drivers/extractors/advisors/notifiers |
| `core/context_engine.py` | Lossless SessionContextCompactor (with video_frame_ocr provenance) & ProjectMemoryManager (Schema 3.0.0) |
| `core/bean_equipment_store.py` | Beanconqueror inventory deduction & freshness lifecycle, AI bag label scanner, Equipment Presets & Subjective Taste Feedback Loop |
| `core/multimodal_vision.py` | Local Whisper audio transcription + FFmpeg 4-stage keyframe pipeline (15%/35%/70%/90%) + live Gemini/OpenAI VLM inspector |
| `core/camera_sta_bridge.py` | Root ADB & USB-C bridge for eagle4_hg224, PCIe wlan0 STA provisioner (/data/pocket-coffee/pocket_sta_agent.sh), :8088 DCIM puller (/mnt/media_rw/emulated/DCIM/DJI_001), DUML [02:02] shutter & [04:14] OsmoDesk gimbal presets |
| `core/analyzer.py` | Multimodal voice/video parameter extractor, barista advisor, 6-axis flavor radar, Xiaohongshu/WeChat copy generator |
| `core/notifier.py` | WeCom, ServerChan, Bark, Feishu, and macOS notification dispatcher (default port 8788) |
| `core/store.py` | JSON repository persistence & sample records |
| `daemon/voice_session.py` | Wake-word, OsmoDesk gimbal stage follower & auto-stop state machine wired to MultimodalVisionEngine, SessionContextCompactor & BeanLibrary |
| `daemon/provision_camera_sta.py` | CLI utility for root ADB STA provisioning and /data/pocket-coffee/pocket_sta_agent.sh deployment |
| `server/app.py` | REST API (/api/camera/sta, /api/camera/media, /api/camera/pull_media, /api/camera/gimbal, /api/media/keyframe, /api/beans/scan_label, /api/records/compare) & static web server (default port 8788) |
| `static/index.html` | Interactive web studio with 4-stage keyframe gallery, :8088 video player, Visualizer dual-shot comparison, and 900x1200 Xiaohongshu radar+keyframe poster exporter |

## 3. 持续迭代路线图 (Iteration Backlog)
- ✅ **ITER-01** (`done`): Core modular scaffold + DUML STA bridge + Voice session pipeline
- ✅ **ITER-02** (`done`): Lossless SessionContextCompactor & ProjectMemoryManager
- ✅ **ITER-03** (`done`): Personal Coffee Bean Library, Equipment Presets & Subjective Taste Calibration Loop
- ✅ **ITER-04** (`done`): Local Whisper + VLM Keyframe Analyzer & USB-C Hardware Probe
- ✅ **ITER-05** (`done`): Live OsmoPocket4P-ANHXP5J0022DTW eagle4_hg224 root ADB + PCIe wlan0 load + wpa_supplicant STA 192.168.5.93 + /data/pocket-coffee/pocket_sta_agent.sh + :8088 HTTP media server (/mnt/media_rw/emulated/DCIM/DJI_001) & live heartbeats
- ✅ **ITER-06** (`done`): Beanconqueror inventory deduction & freshness lifecycle, AI bag label scanner, Visualizer dual-shot comparison, OsmoDesk 04:14 gimbal presets, and FFmpeg 4-stage keyframe pipeline
