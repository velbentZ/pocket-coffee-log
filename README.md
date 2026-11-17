# ☕️ Pocket Coffee Studio (`pocket-coffee-log`)

**基于 DJI Osmo Pocket 4 Pro (`eagle4_hg224`) / Pocket 3 内部 STA 局域网实测接入、语音自动唤醒启停与多模态 AI 的全自动咖啡制作记录与社交分享系统**

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

2. **🎙️ 零人工干预 · 语音唤醒开录 & 多模态 FFmpeg 关键帧抽帧 (`daemon/voice_session.py`, `core/multimodal_vision.py`)**
   - 当检测到唤醒词 **「我要开始制作咖啡」** 或 **「开始做咖啡」** 时，立即触发相机录制并采集多轮口述语音（支持口误自我修正与无损上下文压缩 `SessionContextCompactor`）；
   - 支持本地 `.MP4` 文件与相机远程 HTTP 媒体流（`http://192.168.5.93:8088/DJI_001/...`），当本机安装 `ffprobe` / `ffmpeg` 时自动读取真实视频时长与分辨率，并在 **15% / 35% / 70% / 90%** 四个关键萃取阶段抽取 JPEG 缩略关键帧落盘至 `data/keyframes/<session_or_basename>/`（离线或单元测试环境下自动优雅降级）。

3. **📋 全维度咖啡制作报告、AI 咖啡师建议 & 同款豆萃取对比 (`core/analyzer.py`, `server/app.py`)**
   - 自动提取并结构化记录：
     - **咖啡豆名称/产地/处理法/烘焙度**（联动个人常驻豆仓简称匹配）
     - **咖啡豆称重 (g)**、**研磨度刻度**、**研磨机器类型**（区分 **额外独立磨豆机** 如 Niche Zero / DF64 / Weber EG-1，还是 **咖啡机自身自带磨豆机**）
     - **制作方式**（意式浓缩 Espresso / SOE / 冷萃 Cold Brew / 拿铁 / Dirty）
     - **萃取液重/出液量 (g/ml)**、自动计算的 **粉液比 (Brew Ratio)**、**萃取时间 (s / h)** 与 **萃取压力 (bar)**
   - **📊 Visualizer 风格同款豆并排萃取对比 (`GET /api/records/compare?bean=...`)**：支持对同一支豆或同种萃取方式的历史出品进行粉重、研磨刻度、液重、粉液比、耗时、压力及 **感官风味六维雷达差值 (Delta)** 的并排可视化复盘。

4. **📲 手机端通知提醒 & 缺失参数互动补全 (`core/notifier.py`)**
   - 支持 **企业微信机器人 (WeCom)**、**微信 Server酱**、**iOS Bark**、**飞书机器人** 以及 macOS 本地通知横幅；
   - 若录制过程中漏说关键参数，自动向手机发送 **「⚠️ 咖啡记录待补全」** 提醒（直达 `http://192.168.5.84:8788/?record_id=...&action=supplement`），一句话语音或表单即可补全并重算报告。

5. **📕 小红书 / 微信朋友圈精美海报与种草文案一键导出 (`static/index.html`)**
   - 内置 3:4 比例杂志级咖啡打卡视觉海报生成器（支持一键导出高清 `.png` 海报图片）；
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
adb -s 123456789ABCDEF shell 'chmod 755 /data/pocket-coffee/pocket_sta_agent.sh && /sbin/busybox nohup /system/bin/sh /data/pocket-coffee/pocket_sta_agent.sh </dev/null >/data/pocket-coffee/console.log 2>&1 &'
```

启动后在浏览器或手机端打开：`http://127.0.0.1:8788`（局域网手机访问：`http://192.168.5.84:8788`，相机 `:8088` 媒体服务：`http://192.168.5.93:8088/DJI_001/`）。
