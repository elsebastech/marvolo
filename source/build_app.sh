#!/bin/bash
# Build NoteLive.app — universal (Apple Silicon + Intel), ad-hoc signed.
set -e
cd "$(dirname "$0")"

APP="NoteLive.app"
rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling arm64 + x86_64..."
swiftc -O -target arm64-apple-macosx13.0  -o build/notelive-arm64  notelive.swift
swiftc -O -target x86_64-apple-macosx13.0 -o build/notelive-x86_64 notelive.swift
lipo -create build/notelive-arm64 build/notelive-x86_64 -output "$APP/Contents/MacOS/NoteLive"
chmod +x "$APP/Contents/MacOS/NoteLive"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NoteLive</string>
    <key>CFBundleDisplayName</key><string>NoteLive</string>
    <key>CFBundleIdentifier</key><string>com.sebastian.notelive</string>
    <key>CFBundleExecutable</key><string>NoteLive</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>NoteLive reads pen strokes from your XP-Pen Note Plus notebook over Bluetooth.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/NoteLive"))"
