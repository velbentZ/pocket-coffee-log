#!/bin/bash
set -euo pipefail

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path --sdk iphonesimulator)"
BUILD_DIR="$SCRIPT_DIR/.build-sim"
APP_DIR="$BUILD_DIR/PocketCoffeeApp.app"
BUNDLE_ID="com.pocketcoffee.app"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR"

echo "1/4 Compiling PocketCoffeeCore (arm64-apple-ios17.0-simulator)..."
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios17.0-simulator \
  -whole-module-optimization \
  -emit-module -emit-object \
  -module-name PocketCoffeeCore \
  -parse-as-library \
  -O \
  "$SCRIPT_DIR"/PocketCoffeeCore/Sources/PocketCoffeeCore/*.swift \
  -emit-module-path "$BUILD_DIR/PocketCoffeeCore.swiftmodule" \
  -o "$BUILD_DIR/PocketCoffeeCore.o"

echo "2/4 Compiling PocketCoffeeApp SwiftUI binary..."
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios17.0-simulator \
  -I "$BUILD_DIR" \
  -parse-as-library \
  -O \
  "$SCRIPT_DIR"/PocketCoffeeApp/*.swift \
  "$SCRIPT_DIR"/PocketCoffeeApp/Views/*.swift \
  "$BUILD_DIR/PocketCoffeeCore.o" \
  -framework SwiftUI -framework UIKit -framework Foundation -framework AVFoundation \
  -framework AVKit -framework PhotosUI -framework Speech -framework Vision \
  -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
  -o "$APP_DIR/PocketCoffeeApp"

cat > "$APP_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleDisplayName</key>
  <string>Pocket Coffee</string>
  <key>CFBundleExecutable</key>
  <string>PocketCoffeeApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.pocketcoffee.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PocketCoffeeApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSRequiresIPhoneOS</key>
  <true/>
  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <false/>
  </dict>
  <key>UILaunchScreen</key>
  <dict>
    <key>UIColorName</key>
    <string>AccentColor</string>
  </dict>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>NSCameraUsageDescription</key>
  <string>用于直接拍摄咖啡制作视频与设备介绍画面，全程端侧处理。</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>用于录制制作过程中的语音口述，完成端侧离线转写。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>用于使用苹果端侧语音识别模型将口述转写为咖啡参数，不上传云端。</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>用于从相册选择咖啡制作视频或设备介绍视频进行端侧分析。</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>可选：用于将端侧生成的咖啡报告同步至局域网内的 Mac 服务。</string>
</dict>
</plist>
EOF

echo "3/4 Installing and launching on booted iOS Simulator..."
xcrun simctl install booted "$APP_DIR"
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch booted "$BUNDLE_ID"
open -a Simulator || true

echo "4/4 Capturing verification screenshot..."
sleep 2
xcrun simctl io booted screenshot "$BUILD_DIR/sim-launch.png"
echo "LAUNCHED_OK: $BUILD_DIR/sim-launch.png"
