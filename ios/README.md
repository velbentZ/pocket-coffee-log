# Pocket Coffee Log — 原生 iPhone App (`PocketCoffeeApp`)

100% 端侧离线运行的原生 SwiftUI iPhone 应用，零第三方依赖、零云端 API 调用。支持从相册导入咖啡制作视频、导入文件/语音备忘录、App 内即时录音与文字笔记，在 iPhone 本机完成关键帧抽取、Apple Speech 离线转写、Vision OCR 仪表识别、专业咖啡师诊断与六维风味雷达图生成，并可选将结果同步至 Mac 局域网中枢（`:8788`）。

## 目录结构

- `ios/PocketCoffeeCore/`：纯 Swift Package 核心引擎（模型、JSON 存储、豆库与设备档案、端侧多模态识别与管线）
- `ios/PocketCoffeeApp/`：原生 SwiftUI App 界面层（4 Tab 架构：拍摄/导入、咖啡报告、豆库&设备、端侧AI）
- `ios/project.yml`：XcodeGen 工程配置（iOS 17.0+）

## 环境要求

- macOS 14+ & Xcode 16+（支持 iOS 17.0+ 真机/模拟器）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`

## 1. 运行核心库单元测试

```bash
cd ios/PocketCoffeeCore
swift test
```

## 2. 一键在 iOS 模拟器中直接编译运行（无需 XcodeGen）

```bash
./ios/run_simulator.sh
```

## 3. 生成并打开 Xcode 工程（真机安装）

```bash
cd ios
xcodegen generate
open PocketCoffeeApp.xcodeproj
```

## 3. 部署到 iPhone 真机

1. 用数据线或无线调试连接 iPhone，在 Xcode 顶部选择你的真机目标。
2. 在 `PocketCoffeeApp` Target 的 **Signing & Capabilities** 中选择你的 Apple Developer Team（免费个人 Apple ID 也可直接真机调试），如有 Bundle ID 冲突可改为唯一值（例如 `com.yourname.pocketcoffeelog`）。
3. 点击 **Run (`⌘R`)** 编译并安装到 iPhone。首次运行如提示「不受信任的开发者」，前往 iPhone **设置 → 通用 → VPN 与设备管理** 信任证书即可。
4. 首次使用语音录音、相册选片或离线转写时，按系统弹窗授予麦克风、语音识别与相册权限。

## 4. 可选：同步至 Mac 局域网中枢 (`:8788`)

1. 在 Mac 端启动 Pocket Coffee Log 服务（默认监听 `:8788`）。
2. 确保 iPhone 与 Mac 处于同一局域网，打开 App 的 **「端侧AI」** 标签页。
3. 开启 **「启用局域网自动同步」**，填入 Mac 局域网地址（例如 `http://192.168.1.100:8788`），点击 **「测试 Mac 中枢连接」** 验证通过即可。
