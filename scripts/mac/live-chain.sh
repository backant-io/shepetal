#!/bin/bash
# The published release, read-only (docs/update-test.md): the DMG https://<domain>/download serves, against the .sha256
# next to it and against https://<domain>/appcast.xml (enclosure URL and length, and the EdDSA signature under the
# SUPublicEDKey inside that DMG's own app). It prints codesign and Gatekeeper's verdict for the record; Gatekeeper
# refuses the release because it is not notarized on purpose (Pavel's decision), so that never fails the check.
# The user agent says "bot", so the site does not count this as a download.
#
#   scripts/mac/live-chain.sh            SHEPETAL_DOMAIN overrides shepetal.app
set -euo pipefail
cd "$(dirname "$0")/../.."
SITE=https://${SHEPETAL_DOMAIN:-shepetal.app}
UA="shepetal-update-test-bot/1 (read-only release check)"
T=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/live-chain.XXXXXX")
MNT=$T/mnt
fail() { echo "::error::$*"; exit 1; }
get() { curl -fsSL --retry 3 -A "$UA" "$@"; }

URL=$(get -o "$T/live.dmg" -w '%{url_effective}' "$SITE/download")
echo "$SITE/download -> $URL ($(stat -f %z "$T/live.dmg") bytes)"
[[ $URL == "$SITE"/download/*/Shepetal-*.dmg ]] || fail "$SITE/download did not end at $SITE/download/<v>/Shepetal-<v>.dmg"
get -o "$T/live.dmg.sha256" "$URL.sha256"
get -o "$T/appcast.xml" "$SITE/appcast.xml"
echo "$URL.sha256: $(cat "$T/live.dmg.sha256")"
cat "$T/appcast.xml"

SUM=$(shasum -a 256 "$T/live.dmg" | awk '{ print $1 }')
[ "$SUM" = "$(awk '{ print $1; exit }' "$T/live.dmg.sha256")" ] || fail "the DMG's sha256 $SUM is not the published one"
echo "PASS: sha256 $SUM matches $URL.sha256"
grep -qF "url=\"$URL\"" "$T/appcast.xml" || fail "the appcast does not offer $URL, the DMG /download serves"
LEN=$(stat -f %z "$T/live.dmg")
grep -qF "length=\"$LEN\"" "$T/appcast.xml" || fail "the appcast's enclosure length is not the DMG's $LEN bytes"
echo "PASS: the appcast offers $URL with length $LEN"

mkdir -p "$MNT"
hdiutil attach "$T/live.dmg" -nobrowse -readonly -noautoopen -mountpoint "$MNT" -quiet
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true' EXIT
cp "$MNT/Shepetal.app/Contents/Info.plist" "$T/Info.plist"
BUILD=$(plutil -extract CFBundleVersion raw "$T/Info.plist")
echo "the app inside: $(plutil -extract CFBundleShortVersionString raw "$T/Info.plist") build $BUILD," \
  "SUFeedURL $(plutil -extract SUFeedURL raw "$T/Info.plist"), SUPublicEDKey $(plutil -extract SUPublicEDKey raw "$T/Info.plist")"
[ "$(plutil -extract SUFeedURL raw "$T/Info.plist")" = "$SITE/appcast.xml" ] || fail "the released app's SUFeedURL is not $SITE/appcast.xml"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$T/appcast.xml" || fail "the appcast is not for the released build $BUILD"
swift scripts/mac/verify-update.swift "$T/appcast.xml" "$T/live.dmg" "$T/Info.plist"
echo "PASS: the appcast's EdDSA signature matches the DMG under the SUPublicEDKey inside its app"

echo "== for the record (not checked)"
codesign -dv "$T/live.dmg" 2>&1 | sed 's/^/  codesign dmg: /' || true
codesign -dvv "$MNT/Shepetal.app" 2>&1 | sed 's/^/  codesign app: /' || true
codesign --verify --deep --strict --verbose=2 "$MNT/Shepetal.app" 2>&1 | sed 's/^/  codesign --verify: /' || true
S=0; spctl -a -vv -t exec "$MNT/Shepetal.app" > "$T/spctl-app.txt" 2>&1 || S=$?
sed 's/^/  spctl app: /' "$T/spctl-app.txt"; echo "  spctl app: exit $S"
S=0; spctl -a -vv -t open --context context:primary-signature "$T/live.dmg" > "$T/spctl-dmg.txt" 2>&1 || S=$?
sed 's/^/  spctl dmg: /' "$T/spctl-dmg.txt"; echo "  spctl dmg: exit $S"
S=0; xcrun stapler validate "$T/live.dmg" > "$T/stapler.txt" 2>&1 || S=$?
sed 's/^/  stapler: /' "$T/stapler.txt"; echo "  stapler: exit $S"
echo "Gatekeeper's verdict above is reported, not checked: the release is not notarized on purpose."
echo "== live chain passed: $URL"
