#!/bin/zsh
# 构建 Monitoring.app（无依赖，单文件 Swift）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Monitoring.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/Monitoring"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "构建完成：$PWD/$APP"
echo "安装：rm -rf /Applications/Monitoring.app && cp -R $APP /Applications/"
