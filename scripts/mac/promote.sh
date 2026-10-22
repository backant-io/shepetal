#!/bin/bash
# Publishes a staged Mac release (docs/install-and-update.md 3). LATEST, the release that /download and /appcast.xml
# serve, is latest.json in the R2 bucket shepetal-releases. Only this script writes it, and only after these checks on
# the exact bytes it publishes: the DMG is stapled and accepted by Gatekeeper and matches its .sha256; the appcast's one
# item is signed for that DMG under the SUPublicEDKey inside it (verify-update.swift), is for its CFBundleVersion and
# offers it at ${SUFeedURL%appcast.xml}download/<v>/Shepetal-<v>.dmg; the version and build are above LATEST's.
#
#   scripts/mac/promote.sh 0.2.0            staging/0.2.0/ (CI's upload) → releases/0.2.0/, served at
#                                           /download/0.2.0/…, but not LATEST yet
#   scripts/mac/promote.sh 0.2.0 --latest   the same, then latest.json, last. This is Pavel's GO.
#   scripts/mac/promote.sh 0.1.9 --latest   points LATEST back at a release promoted before (pulling a bad one).
#                                           Sparkle never downgrades anyone who already updated: fix forward.
#   R2='--local --persist-to /abs/dir' SKIP_NOTARY=1 ...   a local R2 and an ad-hoc dry-run DMG (agents, tests)
#   SMOKE=<base url> ...                    where --latest checks /download and /appcast.xml; by default the
#                                           enclosure's site with the remote R2, nowhere with a local one
# R2 defaults to --remote, with Pavel's own wrangler login. It reads the bucket and writes releases/<v>/ and
# latest.json; it never deletes anything.
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "promote: $*" >&2; exit 1; }
V=${1:-} LATEST=0
[ "${2:-}" = --latest ] && LATEST=1
if ! [[ $V =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ $# -ne $((1 + LATEST)) ]; then echo "usage: $0 <x.y.z> [--latest]" >&2; exit 2; fi
R2=${R2:---remote}
if [[ " $R2 " == *" --remote "* ]] && [ "${SKIP_NOTARY:-0}" = 1 ]; then fail "SKIP_NOTARY=1 is only for a local R2"; fi
W=$(mktemp -d)
trap 'hdiutil detach -quiet "$W/mnt" 2>/dev/null || true; rm -rf "$W"' EXIT
DMG=Shepetal-$V.dmg

# Run in $W, so wrangler's .wrangler/ cache stays out of the checkout (a --persist-to DIR must be absolute).
# shellcheck disable=SC2086  # R2 is a list of wrangler flags
r2() { (cd "$W" && WRANGLER_SEND_METRICS=false npx --yes wrangler@4.151.3 r2 object "$@" $R2); }
# get KEY FILE: 0 when fetched, 1 when there is no such object. Any other error stops here, so a failed read is never
# taken for "absent" (which would skip the LATEST check).
get() { local out; out=$(r2 get "shepetal-releases/$1" --file "$2" 2>&1) && return 0
  [[ $out == *"The specified key does not exist"* ]] && return 1
  echo "$out" >&2; fail "could not read $1"; }
put() { r2 put "shepetal-releases/$1" --file "$2" --content-type "$3" >/dev/null; }

# 1. LATEST now, and where the files come from: releases/<v>/ when it was promoted before (repointing LATEST),
#    else staging/<v>/. appcast.xml is written last, so releases/<v>/ without it is a promote that stopped half way.
PV='' PB=''
if get latest.json "$W/latest.json"; then
  PV=$(plutil -extract version raw "$W/latest.json")
  PB=$(plutil -extract build raw "$W/latest.json")
  [[ $PV =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $PB =~ ^[0-9]+$ ]] || fail "latest.json is malformed: $(cat "$W/latest.json")"
fi
if get "releases/$V/appcast.xml" "$W/appcast.xml"; then
  SRC=releases
else
  SRC=staging
  for f in "$DMG" "$DMG.sha256"; do
    if get "releases/$V/$f" "$W/x"; then fail "releases/$V/$f exists without appcast.xml: an earlier promote stopped half way. Compare it with staging/$V/ and delete it by hand."; fi
  done
fi
for f in "$DMG" "$DMG.sha256" appcast.xml; do get "$SRC/$V/$f" "$W/$f" || fail "$SRC/$V/$f does not exist"; done
echo "promote: $V from $SRC/$V/${PV:+, LATEST is $PV (build $PB)}"

# 2. The checks, on the bytes that get published.
[ "$(cat "$W/$DMG.sha256")" = "$(cd "$W" && shasum -a 256 "$DMG")" ] || fail "$DMG.sha256 is not the SHA-256 of $DMG"
if [ "${SKIP_NOTARY:-0}" = 1 ]; then
  echo "promote: SKIP_NOTARY=1, so notarization and Gatekeeper are not checked (local R2 only)" >&2
else
  xcrun stapler validate "$W/$DMG"
  spctl -a -vv -t open --context context:primary-signature "$W/$DMG"
fi
mkdir "$W/mnt"
hdiutil attach "$W/$DMG" -nobrowse -readonly -noautoopen -mountpoint "$W/mnt" -quiet || fail "$DMG does not mount (damaged?)"
cp "$W/mnt/Shepetal.app/Contents/Info.plist" "$W/Info.plist"
[ "${SKIP_NOTARY:-0}" = 1 ] || spctl -a -vv -t exec "$W/mnt/Shepetal.app"
hdiutil detach "$W/mnt" -quiet
[ "$(plutil -extract CFBundleShortVersionString raw "$W/Info.plist")" = "$V" ] || fail "$DMG does not hold version $V"
BUILD=$(plutil -extract CFBundleVersion raw "$W/Info.plist")
[[ $BUILD =~ ^[0-9]+$ ]] || fail "CFBundleVersion $BUILD is not a build number"
FEED=$(plutil -extract SUFeedURL raw "$W/Info.plist") || fail "the app has no SUFeedURL (built without UPDATES=1)"
[[ $FEED == https://*/appcast.xml ]] || fail "SUFeedURL $FEED is not https://<domain>/appcast.xml"
URL=${FEED%appcast.xml}download/$V/$DMG
swift scripts/mac/verify-update.swift "$W/appcast.xml" "$W/$DMG" "$W/Info.plist"
[ "$(grep -c '<item>' "$W/appcast.xml")" = 1 ] || fail "appcast.xml must hold exactly one item"
grep -qF "<sparkle:version>$BUILD</sparkle:version>" "$W/appcast.xml" || fail "appcast.xml is not for build $BUILD"
grep -qF "url=\"$URL\"" "$W/appcast.xml" || fail "appcast.xml does not offer $URL"
if grep -qi github "$W/appcast.xml"; then fail "appcast.xml names GitHub"; fi
# Above LATEST, except when pointing LATEST back at an older (or the same) release promoted before.
if [ -n "$PV" ] && ! { [ "$SRC" = releases ] && printf '%s\n' "$V" "$PV" | sort -V -c 2>/dev/null; }; then
  get "releases/$PV/appcast.xml" "$W/previous.xml" || fail "LATEST is $PV, but releases/$PV/appcast.xml does not exist"
  python3 scripts/mac/release_guard.py --tag "v$V-mac" --build "$BUILD" --main '' --previous "$W/previous.xml" >/dev/null
fi

# 3. Publish: the files (once), then LATEST, last.
if [ "$SRC" = staging ]; then
  put "releases/$V/$DMG" "$W/$DMG" application/x-apple-diskimage
  put "releases/$V/$DMG.sha256" "$W/$DMG.sha256" "text/plain; charset=utf-8"
  put "releases/$V/appcast.xml" "$W/appcast.xml" "application/xml; charset=utf-8"
fi
echo "promote: $V (build $BUILD) is in releases/$V/, served at $URL"
[ "$LATEST" = 1 ] || exit 0
printf '{"version":"%s","build":%s}\n' "$V" "$BUILD" > "$W/latest.json"
put latest.json "$W/latest.json" application/json
echo "promote: LATEST is now $V${PV:+ (was $PV)}"

S=${SMOKE:-}
if [ -z "$S" ] && [[ " $R2 " == *" --remote "* ]]; then S=${URL%%/download/*}; fi
[ -n "$S" ] || exit 0
N=$(date +%s)  # past any edge cache
AGAIN=${PV:+, or point it back with: $0 $PV --latest}
curl -fsS "$S/appcast.xml?promote=$N" | cmp -s - "$W/appcast.xml" || fail "$S/appcast.xml does not serve $V's appcast. Check the site$AGAIN"
curl -fsSL "$S/download?promote=$N" | cmp -s - "$W/$DMG" || fail "$S/download does not lead to $DMG. Check the site$AGAIN"
echo "promote: $S/appcast.xml serves $V's appcast and $S/download leads to $DMG"
