# 🧠 CONTEXT_SNAPSHOT · 上下文无损压缩与持续迭代锚点

> **设计目标**：当对话上下文发生压缩（Context Compaction）或开启新一轮迭代时，读取本文件与 `.context/memory_snapshot.json` 即可 **100% 零信息丢失** 恢复全部架构约束、硬件协议细节、模块契约与迭代进度。

- **Schema 版本**: `2.0.0`
- **GitHub 仓库**: `https://github.com/velbentZ/pocket-coffee-log`
- **本地项目路径**: `/Users/zhengjiaxin/Documents/pocket-coffee-log`
- **默认服务端口**: `8788`

## 1. 核心不可违背约束 (Hard Invariants)
1. 8 Required Brew Fields: bean_name, bean_weight_g, grind_setting, grinder_type (independent vs built-in), grinder_model, brew_method (Espresso vs Cold Brew), yield_g, extraction_time_s, pressure_bar.
2. Single-Camera Active Rotation: User rotates between Pocket 3 and Pocket 4 Pro (one active camera per brew); system automatically binds whichever camera triggers or is selected.
3. Camera Persistent STA Mode: USB-C initial probe/injection + DJI DUML v1 [CmdSet=0x07, CmdId=0x47] switches Pocket 3 / Pocket 4 Pro from AP (192.168.2.1) to persistent Home LAN STA mode.
4. On-Camera Internal Daemon: /data/local/tmp/pocket_sta_agent.sh keeps wpa_supplicant alive, disables wlan0 power_save, exposes DCIM on :8088, and webhooks /api/camera/webhook on MP4 completion.
5. Multimodal AI Engine: Local Whisper speech transcription + VLM keyframe inspection (Gemini / GPT-4o / Claude) for digital scale weight, grinder dial, pressure gauge bar, and shot timer.
6. Personal Bean Library & Subjective Taste Loop: Speaking bean shorthand ('今天用花魁') auto-fills full origin/process/roast & default grinder; post-brew subjective taste rating (偏酸/偏苦/偏淡/黄金平衡) dynamically calibrates next-brew advice.
7. Lossless Context Compaction: SessionContextCompactor preserves provenance + revision history for self-corrections while compressing raw transcripts.

## 2. 模块化架构契约 (Module Contracts)
| 模块路径 | 职责边界与接口契约 |
| :--- | :--- |
| `core/models.py` | Data contracts (CoffeeRecord, FlavorProfile, REQUIRED_BREW_FIELDS) |
| `core/registry.py` | Decoupled EventBus & ModuleRegistry for pluggable drivers/extractors/advisors/notifiers |
| `core/context_engine.py` | Lossless SessionContextCompactor & ProjectMemoryManager |
| `core/bean_equipment_store.py` | Personal Coffee Bean Library (shorthand auto-fill), Equipment Presets & Subjective Taste Feedback Loop |
| `core/multimodal_vision.py` | Local Whisper audio transcription + VLM keyframe analyzer (scale, grinder dial, pressure gauge) |
| `core/camera_sta_bridge.py` | USB-C / Serial / ADB detector, DJI DUML v1 packet builder, STA provisioner, root shell bridge |
| `core/analyzer.py` | Multimodal voice/video parameter extractor, barista advisor, Xiaohongshu/WeChat copy generator |
| `core/notifier.py` | WeCom, ServerChan, Bark, Feishu, and macOS notification dispatcher |
| `core/store.py` | JSON repository persistence & sample records |
| `daemon/voice_session.py` | Wake-word & auto-stop state machine wired to SessionContextCompactor & BeanLibrary |
| `server/app.py` | REST API & static web server (default port 8788) |

## 3. 持续迭代路线图 (Iteration Backlog)
- ✅ **ITER-01** (`done`): Core modular scaffold + DUML STA bridge + Voice session pipeline
- ✅ **ITER-02** (`done`): Lossless SessionContextCompactor & ProjectMemoryManager
- ✅ **ITER-03** (`done`): Personal Coffee Bean Library, Equipment Presets & Subjective Taste Calibration Loop
- ✅ **ITER-04** (`done`): Local Whisper + VLM Keyframe Analyzer & USB-C Hardware Probe
- 🔜 **ITER-05** (`ready`): Live USB-C injection on physical Pocket 3 / Pocket 4 Pro once plugged in + Home Wi-Fi SSID/Password
