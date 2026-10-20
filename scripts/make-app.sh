#!/bin/bash
# Builds dist/Shepetal.app from the SwiftPM release build: menu-bar only (LSUIElement, no Dock icon),
# mic usage text, signed.
#
# Signing: macOS ties granted permissions (Microphone, Input Monitoring, Accessibility) to the app's
# signature. An ad-hoc signature changes with every build, so macOS treats each build as a new app and
# asks again. With a real certificate the designated requirement (bundle ID + certificate) stays the
# same across builds, so permissions survive rebuilds. The script picks, in order:
#   SIGN_IDENTITY=<name or SHA-1>   if set ("-" forces ad-hoc)
#   the first "Developer ID Application" identity in the keychain
#   the first "Apple Development" identity
#   ad-hoc ("-")
#
#   scripts/make-app.sh            build and sign dist/Shepetal.app
#   scripts/make-app.sh --install  also copy it to ~/Applications/Shepetal.app; a copy running from there
#                                  is quit first and opened again afterwards
#   scripts/make-app.sh --zip      also write dist/Shepetal-<version>-mac.zip (+ .sha256) for a release
#   VERSION=0.1.1 scripts/make-app.sh ...   the version shown in Finder and in the zip name (default 0.1.0)
set -euo pipefail
cd "$(dirname "$0")/.."
INSTALL=0; ZIP=0
for a in "$@"; do
  case $a in
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

swift build -c release -j "${JOBS:-4}"
BIN=$(swift build -c release --show-bin-path)
APP=dist/Shepetal.app
SHORT_VERSION=${VERSION:-0.1.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)

pick_identity() {
  if [ -n "${SIGN_IDENTITY:-}" ]; then echo "$SIGN_IDENTITY"; return; fi
  local ids
  ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for kind in "Developer ID Application" "Apple Development"; do
    local sha
    sha=$(printf '%s\n' "$ids" | awk -v k="\"$kind" 'index($0, k) { print $2; exit }')
    if [ -n "$sha" ]; then echo "$sha"; return; fi
  done
  echo -
}
IDENTITY=$(pick_identity)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/shepetal" "$APP/Contents/MacOS/Shepetal"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Dynamic frameworks the binary links (for example llama.cpp for the cleanup model) go in Frameworks.
for f in "$BIN"/*.framework; do
  [ -e "$f" ] || continue
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$f" "$APP/Contents/Frameworks/"
done
if [ -d "$APP/Contents/Frameworks" ]; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Shepetal"
fi
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
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>ShepetalCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Shepetal listens while you hold fn and turns your speech into text on this Mac. Audio never leaves it.</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# Nested code (frameworks, bundles with code) is signed before the app itself.
if [ -d "$APP/Contents/Frameworks" ]; then
  for f in "$APP/Contents/Frameworks"/*; do codesign --force --sign "$IDENTITY" "$f"; done
fi
codesign --force --sign "$IDENTITY" --identifier io.backant.shepetal "$APP"
codesign --verify --strict --verbose=2 "$APP"
if [ "$IDENTITY" = "-" ]; then
  echo "Signed ad-hoc: macOS will ask for permissions again after every rebuild." >&2
else
  echo "Signed with: $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }')"
  codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
fi
echo "Built $PWD/$APP ($SHORT_VERSION, build $BUILD, $COMMIT)"

if [ "$ZIP" = 1 ]; then
  Z=dist/Shepetal-$SHORT_VERSION-mac.zip
  rm -f "$Z"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$Z"
  (cd dist && shasum -a 256 "$(basename "$Z")" | tee "$(basename "$Z").sha256")
fi

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/Shepetal.app"
  EXE="$DEST/Contents/MacOS/Shepetal"
  WAS_RUNNING=0
  if pgrep -qf "^$EXE"; then
    WAS_RUNNING=1
    pkill -f "^$EXE" || true  # only the installed copy, never another Shepetal on this Mac
    for _ in $(seq 1 40); do pgrep -qf "^$EXE" || break; sleep 0.25; done
    if pgrep -qf "^$EXE"; then echo "the running $DEST did not quit; quit it from its 🤫 menu and retry" >&2; exit 1; fi
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
  if [ "$WAS_RUNNING" = 1 ]; then open "$DEST" && echo "Opened it again"; fi
fi
