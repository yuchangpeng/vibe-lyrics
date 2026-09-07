#!/bin/zsh
# 编译并组装 Vibe Lyrics（ad-hoc 签名，本机自用）
# 用法: ./build.sh          仅编译到 build/
#       ./build.sh install  编译并安装到 /Applications/Vibe Lyrics.app
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

if [[ "$1" == "install" ]]; then
    echo "▸ 安装到 /Applications…"
    rm -rf "/Applications/Vibe Lyrics.app"
    cp -R "$APP" "/Applications/Vibe Lyrics.app"
    echo "✓ 已安装：/Applications/Vibe Lyrics.app"
fi

echo "✓ 完成：$APP"
