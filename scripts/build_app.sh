#!/usr/bin/env bash
# Build BLEPrint.app (release, Apple Silicon + Intel when possible) into dist/.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.3.1}"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product BLEPrint "${ARCHS[@]}" 2>/dev/null || { ARCHS=(); swift build -c release --product BLEPrint; }
BIN="$(swift build -c release --product BLEPrint "${ARCHS[@]}" --show-bin-path)/BLEPrint"
APP=dist/BLEPrint.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BLEPrint"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BLEPrint</string>
  <key>CFBundleDisplayName</key><string>BLEPrint</string>
  <key>CFBundleIdentifier</key><string>com.bleprint.swift</string>
  <key>CFBundleExecutable</key><string>BLEPrint</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>BLEPrint uses Bluetooth to connect to your label printer.</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/BLEPrint"))"
