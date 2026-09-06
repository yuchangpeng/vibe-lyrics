#!/bin/zsh
# 编译并组装 桌面歌词.app（ad-hoc 签名，本机自用）
set -e
cd "$(dirname "$0")"

echo "▸ 编译（release）…"
swift build -c release

echo "▸ 组装 app bundle…"
APP="build/DesktopLyrics.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DesktopLyrics "$APP/Contents/MacOS/DesktopLyrics"
cp Support/Info.plist "$APP/Contents/Info.plist"

echo "▸ 签名（ad-hoc）…"
codesign --force --sign - "$APP"

echo "✓ 完成：$APP"
