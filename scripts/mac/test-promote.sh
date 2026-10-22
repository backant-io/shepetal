#!/bin/bash
# scripts/mac/promote.sh against throwaway local R2 buckets, with a dry-run release's verified files. The mac-release.yml
# dry run passes its signed/; by hand, pass a downloaded mac-release-dry-run artifact.
#   scripts/mac/test-promote.sh <dir with Shepetal-<v>.dmg, Shepetal-<v>.dmg.sha256 and appcast.xml>
# What must hold: nothing unchecked, or not above LATEST, is ever written, and LATEST moves only with --latest.
set -euo pipefail
cd "$(dirname "$0")/../.."
A=$(cd "${1:?usage: $0 <dir with the dry-run release files>}" && pwd)
DMG=$(cd "$A" && echo Shepetal-*.dmg)
V=${DMG#Shepetal-}; V=${V%.dmg}
BUILD=$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$A/appcast.xml")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SKIP_NOTARY=1  # the dry run is signed ad-hoc
bad=0
r2() { local d=$1; shift; (cd "$T" && WRANGLER_SEND_METRICS=false npx --yes wrangler@4.151.3 r2 object "$@" --local --persist-to "$d" >/dev/null 2>&1); }
stage() { for f in "$DMG" "$DMG.sha256" appcast.xml; do r2 "$1" put "shepetal-releases/staging/$V/$f" --file "$2/$f"; done; }
has() { r2 "$1" get "shepetal-releases/$2" --file "$T/got"; }
same() { has "$1" "$2" && cmp -s "$T/got" "$3"; }
promote() { R2="--local --persist-to $1" scripts/mac/promote.sh "${@:2}" >"$T/log" 2>&1; }
ok() { echo "ok   $1"; }
refused() { echo "ok   $1: $(tail -1 "$T/log")"; }
no() { echo "FAIL $1"; sed 's/^/     | /' "$T/log"; bad=1; }
nothing_in() { ! has "$1" "releases/$V/$DMG" && ! has "$1" "releases/$V/$DMG.sha256" && ! has "$1" "releases/$V/appcast.xml"; }

# A DMG with one flipped byte (and a .sha256 that matches it) is refused, and nothing is written.
cp -R "$A" "$T/flipped"
python3 -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[4096] ^= 1; open(p, "wb").write(b)' "$T/flipped/$DMG"
(cd "$T/flipped" && shasum -a 256 "$DMG" > "$DMG.sha256")
stage "$T/r2-flipped" "$T/flipped"
if promote "$T/r2-flipped" "$V" --latest; then no "a flipped byte was promoted"
elif nothing_in "$T/r2-flipped" && ! has "$T/r2-flipped" latest.json; then refused "a flipped byte is refused before anything is written"
else no "a flipped byte was refused, but something was written"; fi

# The same app re-packed (other bytes, a matching .sha256, the old appcast) mounts fine; its signature must refuse it.
cp -R "$A" "$T/repacked"
rm "$T/repacked/$DMG"
hdiutil convert "$A/$DMG" -format UDZO -o "$T/repacked/$DMG" -quiet
(cd "$T/repacked" && shasum -a 256 "$DMG" > "$DMG.sha256")
stage "$T/r2-repacked" "$T/repacked"
if promote "$T/r2-repacked" "$V" --latest; then no "a re-packed DMG was promoted under the old signature"
elif nothing_in "$T/r2-repacked" && ! has "$T/r2-repacked" latest.json; then refused "a re-packed DMG is refused before anything is written"
else no "a re-packed DMG was refused, but something was written"; fi

# A release that is not above LATEST is refused, and LATEST stays.
stage "$T/r2-below" "$A"
printf '{"version":"9.9.9","build":%s}\n' "$((BUILD + 1))" > "$T/latest.json"
printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>9.9.9</sparkle:shortVersionString></item></channel></rss>\n' "$((BUILD + 1))" > "$T/previous.xml"
r2 "$T/r2-below" put shepetal-releases/latest.json --file "$T/latest.json"
r2 "$T/r2-below" put shepetal-releases/releases/9.9.9/appcast.xml --file "$T/previous.xml"
if promote "$T/r2-below" "$V" --latest; then no "a release below LATEST was promoted"
elif nothing_in "$T/r2-below" && same "$T/r2-below" latest.json "$T/latest.json"; then refused "a release below LATEST is refused, and LATEST stays"
else no "a release below LATEST was refused, but something was written"; fi

# Without --latest: the exact staged bytes land in releases/<v>/, and there is no LATEST.
stage "$T/r2" "$A"
if ! promote "$T/r2" "$V"; then no "promote $V"
elif same "$T/r2" "releases/$V/$DMG" "$A/$DMG" && same "$T/r2" "releases/$V/$DMG.sha256" "$A/$DMG.sha256" &&
  same "$T/r2" "releases/$V/appcast.xml" "$A/appcast.xml" && ! has "$T/r2" latest.json; then ok "promote $V: releases/$V/ holds the staged bytes, and LATEST is not set"
else no "promote $V: releases/$V/ differs from staging, or LATEST was set"; fi

# With --latest (from releases/<v>/ now): latest.json names the version and build.
printf '{"version":"%s","build":%s}\n' "$V" "$BUILD" > "$T/want.json"
if ! promote "$T/r2" "$V" --latest; then no "promote $V --latest"
elif same "$T/r2" latest.json "$T/want.json"; then ok "promote $V --latest: latest.json is $(cat "$T/want.json")"
else no "promote $V --latest wrote $(cat "$T/got" 2>/dev/null)"; fi

# SKIP_NOTARY never reaches the real bucket.
if R2=--remote scripts/mac/promote.sh "$V" >"$T/log" 2>&1; then no "SKIP_NOTARY=1 ran against --remote"
elif grep -q "SKIP_NOTARY=1 is only for a local R2" "$T/log"; then refused "SKIP_NOTARY=1 is refused with --remote"
else no "SKIP_NOTARY=1 with --remote failed for another reason"; fi

[ "$bad" = 0 ] || { echo "test-promote: FAILED"; exit 1; }
echo "test-promote: ok ($DMG, build $BUILD)"
