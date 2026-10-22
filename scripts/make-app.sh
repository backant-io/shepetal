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
#   scripts/make-app.sh --install  also copy it to /Applications/Shepetal.app (INSTALL_DIR overrides); a
#                                  running Shepetal is quit first and opened again afterwards
#   scripts/make-app.sh --zip      also write dist/Shepetal-<version>-mac.zip (+ .sha256) for a release
#   VERSION=0.1.1 scripts/make-app.sh ...   the version shown in Finder and in the zip name (default 0.1.0)
#   REQUIRE_SIGNIN=1|0 ...         1: dictation needs Google sign-in and a trial or license
#                                  (ShepetalRequiresSignIn in Info.plist). Default 1 with --zip and from
#                                  scripts/make-dmg.sh (the release), else 0, so a build from source dictates
#                                  without signing in. SHEPETAL_REQUIRE_SIGNIN=1|0 overrides it when the app starts.
#   UPDATES=1 ...                  Sparkle auto-updates: writes SUFeedURL and SUPublicEDKey (make-dmg.sh does).
#                                  Without it the app never updates itself, so a release never replaces a dev build.
#   SHEPETAL_DOMAIN=<host> ...     with UPDATES=1, the feed is https://<host>/appcast.xml (default below)
#   TIMESTAMP=1 ...                a secure timestamp on every signature (notarization needs it; needs the network)
#   EXPECT_DR=<file> ...           fail unless the app's designated requirement is exactly the one in <file>
#
# A real identity signs with the hardened runtime and scripts/mac/Shepetal.entitlements, nested code first
# (Sparkle's helpers, then each framework, then the app), never with --deep.
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
REQUIRE_SIGNIN=${REQUIRE_SIGNIN:-$ZIP}
# Sparkle's EdDSA public key (public by design). Its private key is in Pavel's login Keychain and in the
# mac-release environment's SPARKLE_ED_PRIVATE_KEY; it is never committed (docs/install-and-update.md 3).
# A release dry run without that key passes a throwaway one (its DMG can never update).
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-aXU+sm8y+UDKwB2M7DxhacVN/BAgTqMsHq2rMc3fibs=}
# The one place the update domain lives. release.sh and mac-release.yml read the feed URL back from the built app
# for the appcast's download URLs, so the DMG is served from the same site. Every shipped build keeps it.
SHEPETAL_DOMAIN=${SHEPETAL_DOMAIN:-shepetal.backant.io}
[[ $SHEPETAL_DOMAIN =~ ^[a-z0-9.-]+$ ]] || { echo "SHEPETAL_DOMAIN must be a bare host name: $SHEPETAL_DOMAIN" >&2; exit 2; }
case ${UPDATES:-0} in
  1) UPDATE_KEYS="<key>SUFeedURL</key><string>https://$SHEPETAL_DOMAIN/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUAutomaticallyUpdate</key><true/>"; UPDATES_NOTE="updates on" ;;
  0) UPDATE_KEYS=''; UPDATES_NOTE="updates off" ;;
  *) echo "UPDATES must be 1 or 0" >&2; exit 2 ;;
esac
case $REQUIRE_SIGNIN in
  1) SIGNIN_KEY='<key>ShepetalRequiresSignIn</key><true/>'; SIGNIN="sign-in required" ;;
  0) SIGNIN_KEY=''; SIGNIN="sign-in not required" ;;
  *) echo "REQUIRE_SIGNIN must be 1 or 0" >&2; exit 2 ;;
esac

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
# The app icon is 🤫, rendered from the emoji font at every size (scripts/make-icon.swift).
ICON=.cache/AppIcon.icns
if [ ! -f "$ICON" ] || [ scripts/make-icon.swift -nt "$ICON" ]; then
  mkdir -p .cache
  swift scripts/make-icon.swift .cache/AppIcon.iconset
  iconutil -c icns .cache/AppIcon.iconset -o "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp scripts/uninstall-mac.sh "$APP/Contents/Resources/uninstall.sh"  # removes the app, keeps recordings
# Dynamic frameworks the binary links (Sparkle, llama.cpp for the cleanup model) go in Frameworks. ditto keeps
# a versioned framework's symlinks. Sparkle's XPC services are only for sandboxed apps, and this one is not.
for f in "$BIN"/*.framework; do
  [ -e "$f" ] || continue
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$f" "$APP/Contents/Frameworks/$(basename "$f")"
done
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>ShepetalCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Shepetal listens while you hold fn and turns your speech into text on this Mac. Audio never leaves it.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Shepetal records the other people in a meeting so it can transcribe it on this Mac. Audio never leaves it.</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  $SIGNIN_KEY
  $UPDATE_KEYS
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

SIGN=(--force --sign "$IDENTITY")
[ "${TIMESTAMP:-0}" = 1 ] && SIGN+=(--timestamp) || SIGN+=(--timestamp=none)
APP_SIGN=()
if [ "$IDENTITY" != - ]; then SIGN+=(--options runtime); APP_SIGN=(--entitlements scripts/mac/Shepetal.entitlements); fi
# Inside-out: Sparkle's helpers, then each framework, then the app.
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
for n in "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do [ -e "$n" ] && codesign "${SIGN[@]}" "$n"; done
if [ -d "$APP/Contents/Frameworks" ]; then
  for f in "$APP/Contents/Frameworks"/*; do codesign "${SIGN[@]}" "$f"; done
fi
codesign "${SIGN[@]}" ${APP_SIGN[@]+"${APP_SIGN[@]}"} --identifier io.backant.shepetal "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [ -n "${EXPECT_DR:-}" ]; then
  DR=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
  if [ "$DR" != "$(cat "$EXPECT_DR")" ]; then
    printf 'The designated requirement changed, so every user would have to grant the permissions again.\n  built:  %s\n  pinned: %s (%s)\n' "$DR" "$(cat "$EXPECT_DR")" "$EXPECT_DR" >&2
    exit 1
  fi
fi
if [ "$IDENTITY" = "-" ]; then
  echo "Signed ad-hoc: macOS will ask for permissions again after every rebuild." >&2
else
  echo "Signed with: $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }')"
  codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
fi
echo "Built $PWD/$APP ($SHORT_VERSION, build $BUILD, $COMMIT, $SIGNIN, $UPDATES_NOTE)"

if [ "$ZIP" = 1 ]; then
  Z=dist/Shepetal-$SHORT_VERSION-mac.zip
  rm -f "$Z"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$Z"
  (cd dist && shasum -a 256 "$(basename "$Z")" | tee "$(basename "$Z").sha256")
fi

if [ "$INSTALL" = 1 ]; then
  # /Applications is writable by admin users without sudo. A running Shepetal is asked to quit (the
  # normal way, like its menu's Quit), replaced, and opened again. An older copy in ~/Applications is
  # removed, so macOS sees one Shepetal and its permissions belong to the one in /Applications.
  DEST=${INSTALL_DIR:-/Applications}/Shepetal.app
  WAS_RUNNING=0
  if pgrep -qx Shepetal; then
    WAS_RUNNING=1
    osascript -e 'quit app "Shepetal"' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -qx Shepetal || break; sleep 0.25; done
    if pgrep -qx Shepetal; then echo "Shepetal did not quit; quit it from its 🤫 menu and retry" >&2; exit 1; fi
  fi
  rm -rf "$DEST" 2>/dev/null || true  # set -e: a root-owned copy must reach the message below
  if [ -e "$DEST" ]; then
    echo "Cannot replace $DEST: the old .pkg installer made it root-owned. Move it to the Trash in Finder first." >&2
    [ "$WAS_RUNNING" = 1 ] && open "$DEST"
    exit 1
  fi
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
  OLD="$HOME/Applications/Shepetal.app"
  if [ "$DEST" != "$OLD" ] && [ -d "$OLD" ]; then rm -rf "$OLD" && echo "Removed the old copy $OLD"; fi
  if [ "$WAS_RUNNING" = 1 ]; then open "$DEST" && echo "Opened it again"; fi
fi
