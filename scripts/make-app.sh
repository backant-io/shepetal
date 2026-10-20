#!/bin/bash
# Builds dist/Shepetal.app from the SwiftPM release build: menu-bar only (LSUIElement), mic usage text,
# ad-hoc signature. Ad-hoc signatures change with every build, so macOS asks for permissions again.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=dist/Shepetal.app
VERSION=$(git describe --tags --always 2>/dev/null || echo 0)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/shepetal" "$APP/Contents/MacOS/Shepetal"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.backant.shepetal</string>
  <key>CFBundleName</key><string>Shepetal</string>
  <key>CFBundleDisplayName</key><string>Shepetal</string>
  <key>CFBundleExecutable</key><string>Shepetal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Shepetal listens while you hold fn and turns your speech into text on this Mac. Audio never leaves it.</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --identifier io.backant.shepetal "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $PWD/$APP"
