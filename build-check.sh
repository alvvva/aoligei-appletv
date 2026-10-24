#!/bin/zsh
# 装好 Xcode 和 tvOS 平台后运行：在 tvOS 模拟器上编译一遍，确认工程能通过编译。
set -e
cd "$(dirname "$0")"
command -v xcodegen >/dev/null && xcodegen generate
xcodebuild -project TVBrowser.xcodeproj -scheme TVBrowser \
  -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | tail -20
echo "编译成功：build/Build/Products/Debug-appletvsimulator/TVBrowser.app"
