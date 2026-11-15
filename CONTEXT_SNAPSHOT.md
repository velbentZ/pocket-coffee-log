# 🧠 CONTEXT_SNAPSHOT · 上下文无损压缩与持续迭代锚点

> **设计目标**：当对话上下文发生压缩（Context Compaction）或开启新一轮迭代时，读取本文件与 `.context/memory_snapshot.json` 即可 **100% 零信息丢失** 恢复全部架构约束、硬件协议细节、模块契约与迭代进度。

- **Schema 版本**: `2.0.0`
- **GitHub 仓库**: `https://github.com/velbentZ/pocket-coffee-log`
- **本地项目路径**: `/Users/zhengjiaxin/Documents/pocket-coffee-log`
- **默认服务端口**: `8788`

## 1. 核心不可违背约束 (Hard Invariants)
1. 8 Required Brew Fields: bean_name, bean_weight_g, grind_setting, grinder_type (independent vs built-in), grinder_model, brew_method (Espresso vs Cold Brew), yield_g, extraction_time_s, pressure_bar.
2. Camera Persistent STA Mode: DJI DUML v1 [CmdSet=0x07, CmdId=0x47] switches Pocket 3 / Pocket 4 Pro from AP (192.168.2.1) to persistent Home LAN STA mode.
3. On-Camera Internal Daemon: /data/local/tmp/pocket_sta_agent.sh keeps wpa_supplicant alive, disables wlan0 power_save, exposes DCIM on :8088, and webhooks /api/camera/webhook on MP4 completion.
4. Zero-Intervention Voice Pipeline: Wake phrase '我要开始制作咖啡' triggers DUML [02:02] start; stop phrase '制作完成' or silence stops recording, runs AI analysis, and pushes mobile alert.
5. Missing Parameter Loop: Any missing required field marks status='needs_info' and sends interactive supplement link to WeCom/ServerChan/Bark/Mobile UI.
6. Lossless Context Compaction: SessionContextCompactor preserves provenance + revision history for self-corrections while compressing raw transcripts.

## 2. 模块化架构契约 (Module Contracts)
| 模块路径 | 职责边界与接口契约 |
| :--- | :--- |
| `core/models.py` | Data contracts (CoffeeRecord, FlavorProfile, REQUIRED_BREW_FIELDS) |
| `core/registry.py` | Decoupled EventBus & ModuleRegistry for pluggable drivers/extractors/advisors/notifiers |
| `core/context_engine.py` | Lossless SessionContextCompactor & ProjectMemoryManager |
| `core/camera_sta_bridge.py` | DJI DUML v1 packet builder, STA provisioner, ADB TCP (:5555) root shell bridge |
| `core/analyzer.py` | Multimodal voice/video parameter extractor, barista advisor, Xiaohongshu/WeChat copy generator |
| `core/notifier.py` | WeCom, ServerChan, Bark, Feishu, and macOS notification dispatcher |
| `core/store.py` | JSON repository persistence & sample records |
| `daemon/voice_session.py` | Wake-word & auto-stop state machine wired to SessionContextCompactor |
| `server/app.py` | REST API & static web server (default port 8788) |

## 3. 持续迭代路线图 (Iteration Backlog)
- ✅ **ITER-01** (`done`): Core modular scaffold + DUML STA bridge + Voice session pipeline
- ✅ **ITER-02** (`done`): Lossless SessionContextCompactor & ProjectMemoryManager
- 🔜 **ITER-03** (`ready`): Real-time RTSP frame OCR for digital coffee scale & pressure gauge
- 🔜 **ITER-04** (`ready`): BLE GATT (0xFFF5) auto-wakeup from deep sleep on macOS CoreBluetooth
