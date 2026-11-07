#!/bin/bash
set -euo pipefail
RELAY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELAY_BUILD="$RELAY_ROOT/.build/manual"
RELAY_OUTPUT="${1:-$RELAY_ROOT/dist/Vibe Fishing.app}"
RELAY_ARCH="$(uname -m)"
# A stable identity keeps macOS permissions across rebuilds. Falls back to ad-hoc
# on machines without the local certificate (permissions then reset per build).
if [ -z "${RELAY_SIGNING_IDENTITY:-}" ] && /usr/bin/security find-certificate -c "MoyuRelay Local Signing" >/dev/null 2>&1; then
  RELAY_SIGNING_IDENTITY="MoyuRelay Local Signing"
fi
RELAY_SIGNING_IDENTITY="${RELAY_SIGNING_IDENTITY:--}"
RELAY_DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
if [ ! -d "$RELAY_DEVELOPER_DIR" ]; then RELAY_DEVELOPER_DIR="$(xcode-select -p)"; fi
mkdir -p "$RELAY_BUILD" "$RELAY_ROOT/.build/module-cache"
cd "$RELAY_ROOT"
RELAY_FLAGS=(-O -swift-version 5 -target "$RELAY_ARCH-apple-macosx13.0" -module-cache-path "$RELAY_ROOT/.build/module-cache")
DEVELOPER_DIR="$RELAY_DEVELOPER_DIR" xcrun swiftc "${RELAY_FLAGS[@]}" -parse-as-library -emit-library -static -emit-module -module-name RelayCore Sources/RelayCore/*.swift -emit-module-path "$RELAY_BUILD/RelayCore.swiftmodule" -o "$RELAY_BUILD/libRelayCore.a"
DEVELOPER_DIR="$RELAY_DEVELOPER_DIR" xcrun swiftc "${RELAY_FLAGS[@]}" -parse-as-library -I "$RELAY_BUILD" -L "$RELAY_BUILD" -lRelayCore Sources/MoyuRelay/*.swift -o "$RELAY_BUILD/MoyuRelay"
DEVELOPER_DIR="$RELAY_DEVELOPER_DIR" xcrun swiftc "${RELAY_FLAGS[@]}" Sources/relayctl/main.swift -o "$RELAY_BUILD/relayctl"
mkdir -p "$RELAY_OUTPUT/Contents/MacOS" "$RELAY_OUTPUT/Contents/Resources"
cp "$RELAY_BUILD/MoyuRelay" "$RELAY_OUTPUT/Contents/MacOS/MoyuRelay"
cp "$RELAY_BUILD/relayctl" "$RELAY_OUTPUT/Contents/MacOS/relayctl"
cp docs/HOOKS.md "$RELAY_OUTPUT/Contents/Resources/HOOKS.md"
cp Assets/AppIcon.icns "$RELAY_OUTPUT/Contents/Resources/AppIcon.icns"
cp scripts/generate-hook-config.py "$RELAY_OUTPUT/Contents/Resources/generate-hook-config.py"
cat > "$RELAY_OUTPUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.moyu.relay</string>
<key>CFBundleName</key><string>Vibe Fishing</string>
<key>CFBundleDisplayName</key><string>Vibe Fishing</string>
<key>CFBundleExecutable</key><string>MoyuRelay</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.60</string>
<key>CFBundleVersion</key><string>79</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAudioCaptureUsageDescription</key><string>只读取 iPhone 镜像的音量数值，用来判断视频是否在播放；不录音、不保存。</string>
<key>NSAccessibilityUsageDescription</key><string>识别 AI 应用是否在生成，点击镜像切换播放和暂停，并高亮 AI 窗口。</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign "$RELAY_SIGNING_IDENTITY" --identifier com.moyu.relay.bridge "$RELAY_OUTPUT/Contents/MacOS/relayctl"
/usr/bin/codesign --force --sign "$RELAY_SIGNING_IDENTITY" --identifier com.moyu.relay "$RELAY_OUTPUT"
/usr/bin/codesign --verify --deep --strict "$RELAY_OUTPUT"
printf 'Built: %s\n' "$RELAY_OUTPUT"
