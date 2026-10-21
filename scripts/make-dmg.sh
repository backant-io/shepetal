#!/bin/bash
# Builds the drag-and-drop installer dist/Shepetal-<version>.dmg (+ .sha256): a Finder window with Shepetal.app, an
# Applications alias and the brand background (docs/install-and-update.md 1). The same DMG, notarized and stapled by
# scripts/mac/release.sh, is the Sparkle update archive, so there is no zip and no .pkg.
#
#   scripts/make-dmg.sh            runs scripts/make-app.sh with REQUIRE_SIGNIN=1 and UPDATES=1, then builds the DMG
#   VERSION=0.2.0 ...              the version (default 0.1.0)
#   SKIP_APP=1 ...                 package the dist/Shepetal.app already there
# The DMG is signed with the app's identity unless the app is signed ad-hoc. It needs uv (uvx runs dmgbuild).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.1.0}
export VERSION
export REQUIRE_SIGNIN=${REQUIRE_SIGNIN:-1} UPDATES=${UPDATES:-1}  # the release requires sign-in and updates itself
[ "${SKIP_APP:-0}" = 1 ] || scripts/make-app.sh
APP=dist/Shepetal.app
[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION" ] ||
  { echo "$APP is not version $VERSION: rebuild it without SKIP_APP=1" >&2; exit 2; }

W=.cache/dmg
rm -rf "$W"; mkdir -p "$W"
swift scripts/mac/dmg-background.swift "$W"
tiffutil -cathidpicheck "$W/background.png" "$W/background@2x.png" -out "$W/background.tiff" >/dev/null
OUT=dist/Shepetal-$VERSION.dmg
rm -f "$OUT"
uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/mac/dmg-settings.py -D app="$APP" -D background="$W/background.tiff" \
  -D icon="$APP/Contents/Resources/AppIcon.icns" Shepetal "$OUT"

ID=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !n++ { print $2 }')  # no early exit: pipefail + SIGPIPE
if [ -n "$ID" ]; then
  TS=--timestamp=none; [ "${TIMESTAMP:-0}" = 1 ] && TS=--timestamp
  codesign --force --sign "$ID" "$TS" "$OUT"
  echo "Signed the DMG with: $ID"
else
  echo "The DMG is not signed (the app is signed ad-hoc)." >&2
fi
(cd dist && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "Built $PWD/$OUT"
