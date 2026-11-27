# ☕️ 萃镜 · BrewLens

**不限拍摄设备、100% 端侧离线多模态 AI 的全流程咖啡萃取分析、豆库赏味期管理、多品牌器具档案与小红书精排分享工作室（支持 iPhone / iPad / DJI Pocket / GoPro / Mac 本地桌面中枢）**

---

## ✨ 核心特性

1. **📡 相机内部真机实测 · STA 局域网扩展架构 (`core/camera_sta_bridge.py`)**
   - **真机实测平台 (`OsmoPocket4P-ANHXP5J0022DTW` / `eagle4_hg224`)**：通过 Root ADB (`2ca3:0020`, USB Serial `123456789ABCDEF`, Linux `5.4.123-rt59` aarch64) 进入相机内部环境，将驻留守护脚本部署至可写持久化分区 `/data/pocket-coffee/pocket_sta_agent.sh`（`/system` 与 `/vendor` 为只读 ext4，未修改固件且未声称冷启动自动自启，进程存活期间自动维持 STA 关联与租约）。
   - **PCIe Wi-Fi 唤醒与 WPA2-PSK Station 接入**：
     - 相机开机后默认会卸载 PCIe Wi-Fi，守护脚本通过向 `/sys/devices/platform/soc/c080000.apb/c448000.pcie/status` 写入 `load` 动态加载 `aic8800m80x2p_fdrv` 恢复 `wlan0`（不影响 USB ADB）；
     - 修正配置文件属主与 SELinux 标签（`chown wifi:wifi /data/misc/wifi/pocket_sta.conf && chmod 600 && restorecon`），启动 `wpa_supplicant -B -i wlan0 -c /data/misc/wifi/pocket_sta.conf -D nl80211` 并调用 `/sbin/busybox udhcpc -b -i wlan0 -s /system/bin/udhcpc.conf.sh` 获取局域网租约（实测固定分配 `192.168.5.93/24`，MAC `88:22:33:77:33:99`）。
   - **BusyBox `:8088` 媒体直拉服务 & 双向心跳校验**：
     - 在相机内启动 `/sbin/busybox httpd -p 8088 -h /mnt/media_rw/emulated/DCIM`，局域网可直接通过 `http://192.168.5.93:8088/DJI_001/...` 高速预览与拉取 `.MP4` 原片（`GET /api/camera/media`）；
     - 守护进程周期性通过 BusyBox `nc` 向宿主机发送真实源 IP 心跳 `POST /api/camera/heartbeat`（目标 `http://192.168.5.84:8788`），服务端严格核验请求源 IP 与上报 STA IP 一致性，并支持录制完成自动触发 `POST /api/camera/webhook`。

2. **🎙️ 零人工干预 · 语音唤醒开录、OsmoDesk 云台自动跟拍 & 语音感知选帧与本地 OCR 恢复 (`daemon/voice_session.py`, `core/multimodal_vision.py`)**
   - 当检测到唤醒词 **「我要开始制作咖啡」** 或 **「开始做咖啡」** 时，立即触发相机录制并采集多轮口述语音（支持口误自我修正与无损上下文压缩 `SessionContextCompactor`）；
   - **🎯 OsmoDesk 云台机位预设联动 (`POST /api/camera/gimbal`)**：内置 `P0 回中 (reset_center)`、`P1 电子秤称豆 (scale_dose)`、`P2 磨豆刻度 (grinder_dial)`、`P3 压力表油脂 (espresso_gauge)`、`P4 出杯读秒 (final_cup)` 五组云台预设；在口述过程检测到「称豆 / 磨豆刻度 / 萃取压力 / 出液完成」等阶段词时自动驱动相机云台跟随动作；
   - **⬇️ 无线拉取 MP4、智能选帧与视觉补全**：拉取接口默认选择最新视频，也可用 `filename` 指定文件。弱语音或静音会尝试从原片提取音轨转录；按实际语音时间或冲煮阶段窗口，在称豆、磨豆、压力和出杯各比较最多 4 个候选。macOS 优先使用 AVFoundation 和 Apple Vision，按画面清晰度、曝光及 OCR 文本选帧；FFmpeg 可作为抽帧后备。无需 API 密钥即可从清楚的读数补全克重、刻度、压力与读秒；配置 `GEMINI_API_KEY` 或 `OPENAI_API_KEY` 时，VLM 读数优先于本地 OCR。报告保留实际选帧时间与原片链接。

3. **🫘 Beanconqueror 风格豆仓余量、赏味期生命周期 & AI 豆袋标签一键入库 (`core/bean_equipment_store.py`)**
   - **库存扣减与赏味期追踪 (`deduct_bean_dose`)**：为每袋咖啡豆维护 `roast_date`、`initial_weight_g`、`remaining_weight_g`、`bag_status` (`active` / `frozen` / `finished`) 与累计冲煮次数 `brew_count`；每次完成制作后自动扣减豆重并计算烘焙天数 `days_off_roast` 与状态（0–4 天 `养豆期 (Degassing)`、5–28 天 `黄金赏味期 (Peak Window)`、>28 天 `风味衰退期 (Aging)`）；
   - **🏷️ AI 豆袋标签解析入库 (`POST /api/beans/scan_label` / `parse_bean_label_text`)**：粘贴或语音口述豆袋标签（如 `"巴拿马翡翠庄园红标瑰夏 日晒 浅烘 200g 柑橘茉莉花水蜜桃 烘焙日期 2026-11-10"`）即可一键解析结构化产地、处理法、烘焙度、风味标签、净含量与烘焙日期并同步入库。

4. **📋 全维度咖啡制作报告、4 阶段视觉抽帧画廊 & 同款豆萃取对比 (`core/analyzer.py`, `server/app.py`)**
   - 自动提取并结构化记录：
     - **咖啡豆名称/产地/处理法/烘焙度**（联动个人常驻豆仓简称匹配）
     - **咖啡豆称重 (g)**、**研磨度刻度**、**研磨机器类型**（区分 **额外独立磨豆机** 如 Niche Zero / DF64 / Weber EG-1，还是 **咖啡机自身自带磨豆机**）
     - **制作方式**（意式浓缩 Espresso / SOE / 冷萃 Cold Brew / 拿铁 / Dirty）
     - **萃取液重/出液量 (g/ml)**、自动计算的 **粉液比 (Brew Ratio)**、**萃取时间 (s / h)** 与 **萃取压力 (bar)**
   - **🖼️ 报告内嵌 4 阶段视觉抽帧画廊 & `:8088` 原片直播**：每份报告卡片内置 `P1 称豆 / P2 刻度 / P3 压力表 / P4 出杯` 抽帧缩略图画廊（`GET /api/media/keyframe?path=...`）以及 **「🎬 播放本杯相机原始视频」** 一键回放抽屉；
   - **📊 Visualizer 风格同款豆并排萃取对比 (`GET /api/records/compare?bean=...`)**：支持对同一支豆或同种萃取方式的历史出品进行粉重、研磨刻度、液重、粉液比、耗时、压力及 **感官风味六维雷达差值 (Delta)** 的并排可视化复盘。

5. **📲 手机端通知提醒 & 缺失参数互动补全 (`core/notifier.py`)**
   - 支持 **企业微信机器人 (WeCom)**、**微信 Server酱**、**iOS Bark**、**飞书机器人** 以及 macOS 本地通知横幅；
   - 若录制过程中漏说关键参数，自动向手机发送 **「⚠️ 咖啡记录待补全」** 提醒（直达 `http://192.168.5.84:8788/?record_id=...&action=supplement`），一句话语音或表单即可补全并重算报告。

6. **📕 小红书 / 微信朋友圈 900×1200 六维雷达 + 实拍抽帧合成海报导出 (`static/index.html`)**
   - 内置 3:4 (`900×1200`) 杂志级咖啡打卡视觉海报 `<canvas>` 合成器：直接在导出 `.png` 海报上绘制 **感官风味六维雷达图多边形**，并自动合成至多 **2 张相机实拍关键帧快照**（或咖啡师认证评分印章）；
   - 自动撰写带 Emoji 与热门标签的 **小红书图文笔记** 与 **微信朋友圈打卡文案**。

---

## 🚀 快速启动

```bash
# 1. 运行单元测试套件
python3 -m unittest discover -s tests -p "test_*.py" -v

# 2. 启动 Pocket Coffee Studio 服务 (默认监听端口 8788)
PORT=8788 python3 server/app.py

# 3. 通过 USB Root ADB 在 Osmo Pocket 4 Pro (eagle4_hg224) 内启动 STA 守护进程
adb -s 123456789ABCDEF push data/pocket_sta_agent.sh /data/pocket-coffee/pocket_sta_agent.sh
adb -s 123456789ABCDEF shell 'chmod 755 /data/pocket-coffee/pocket_sta_agent.sh && { /sbin/busybox setsid sh /data/pocket-coffee/pocket_sta_agent.sh </dev/null >/dev/null 2>&1 & }'
```

启动后在浏览器或手机端打开：`http://127.0.0.1:8788`（局域网手机访问：`http://192.168.5.84:8788`，相机 `:8088` 媒体服务：`http://192.168.5.93:8088/DJI_001/`）。
