# ☕️ Pocket Coffee Studio (`pocket-coffee-log`)

**基于 DJI Osmo Pocket 3 / Pocket 4 Pro 内部 STA 局域网扩展、语音自动唤醒启停与多模态 AI 的全自动咖啡制作记录与社交分享系统**

---

## ✨ 核心特性

1. **📡 深入相机内部 · 持久 STA 局域网模式扩展 (`core/camera_sta_bridge.py`)**
   - **突破默认临时 AP 限制**：支持通过 DJI DUML v1 协议 (`CmdSet=0x07, CmdId=0x47`) 将 Osmo Pocket 3 与 Pocket 4 Pro 从默认的 `192.168.2.1` AP 模式切换为持久连接家庭路由器的 **STA 客户端模式**（如固定分配 `192.168.5.108` / `192.168.5.109`）。
   - **相机内部驻留守护脚本 (`/data/local/tmp/pocket_sta_agent.sh`)**：通过 ADB over TCP (`:5555`) 进入相机内部 Ambarella/Android Linux 环境：
     - 关闭 `wlan0` 休眠省电策略 (`iw dev wlan0 set power_save off`)，使用 `wpa_supplicant` 持久锁定路由器 STA 网络；
     - 在相机内部启动 BusyBox HTTP 媒体直拉服务 (`:8088`)，暴露 `/storage/sdcard0/DCIM`；
     - 实时监控相册目录，一旦录制结束生成完整的 `.MP4` 视频文件，相机内部主动通过 Webhook (`POST /api/camera/webhook`) 通知局域网服务器高速拉片并触发 AI 分析。

2. **🎙️ 零人工干预 · 语音唤醒开录 & 自动停录 (`daemon/voice_session.py`)**
   - 当检测到唤醒词 **「我要开始制作咖啡」** 或 **「开始做咖啡」** 时，立即通过局域网向相机发送 DUML `[02:02]` 快门指令开始录制；
   - 制作过程中自动采集口述语音与画面时间轴；
   - 当识别到 **「咖啡制作完成 / 制作结束」** 或萃取结束静默超时，自动停止相机录制、拉取视频并在后台完成解析。

3. **📋 全维度咖啡制作报告 & AI 咖啡师建议 (`core/analyzer.py`)**
   - 自动提取并结构化记录：
     - **咖啡豆名称/产地/处理法/烘焙度**
     - **咖啡豆称重 (g)**
     - **研磨度刻度**
     - **研磨机器类型**（区分 **额外独立磨豆机** 如 Niche Zero / DF64 / Weber EG-1，还是 **咖啡机自身自带磨豆机**）
     - **制作方式**（意式浓缩 Espresso / SOE / 冷萃 Cold Brew / 拿铁 / Dirty）
     - **萃取液重/出液量 (g/ml)** 与自动计算的 **粉液比 (Brew Ratio)**
     - **萃取时间 (s / h)**
     - **萃取压力 (bar)**
   - 生成 **感官风味六维雷达图**、**视频+语音多模态关键帧时间轴**，以及针对性的 **下一次萃取优化建议**。

4. **📲 手机端通知提醒 & 缺失参数互动补全 (`core/notifier.py`)**
   - 支持 **企业微信机器人 (WeCom)**、**微信 Server酱**、**iOS Bark**、**飞书机器人** 以及本地通知横幅；
   - 若某次录制过程中漏说了某个参数（例如未提到研磨度或萃取压力），自动向手机发送 **「⚠️ 咖啡记录待补全」** 提醒，点击即可在手机端一句话语音或表单补全并实时重算报告。

5. **📕 小红书 / 微信朋友圈精美海报与种草文案一键导出 (`static/index.html`)**
   - 内置 3:4 比例杂志级咖啡打卡视觉海报生成器（支持一键导出高清 `.png` 海报图片）；
   - 自动撰写带 Emoji 与热门标签的 **小红书图文笔记** 与 **微信朋友圈打卡文案**。

---

## 🚀 快速启动

```bash
# 1. 运行单元测试
python3 -m unittest discover -s tests

# 2. 启动 Pocket Coffee Studio 服务 (默认端口 8765)
python3 server/app.py

# 3. 命令行下发相机 STA 持久配网与内部守护脚本
python3 daemon/provision_camera_sta.py --device pocket4p --ssid "Home_Coffee_LAN" --password "your_wifi_pwd" --lan-ip 192.168.5.108 --exec "iw dev wlan0 info && ps"
```

启动后在浏览器或手机端打开：`http://127.0.0.1:8765`（局域网手机访问：`http://192.168.5.84:8765`）。
