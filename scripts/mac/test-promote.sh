#!/bin/bash
# scripts/mac/promote.sh against throwaway local R2 buckets, with a dry-run release's verified files. The mac-release.yml
# dry run passes its signed/; by hand, pass a downloaded mac-release-dry-run artifact.
#   scripts/mac/test-promote.sh <dir with Shepetal-<v>.dmg, Shepetal-<v>.dmg.sha256 and appcast.xml>
# What must hold: nothing unchecked, or not above LATEST, is ever written, LATEST moves only with --latest, and
# `promote.sh <previous> --latest` (pulling a bad release) always works. Every promote below passes --unnotarized
# (Pavel ships unnotarized, 22.10.26; the dry run is signed ad-hoc), so each refusal shows that the flag skips only
# the staple and Gatekeeper checks.
set -euo pipefail
cd "$(dirname "$0")/../.."
A=$(cd "${1:?usage: $0 <dir with the dry-run release files>}" && pwd)
DMG=$(cd "$A" && echo Shepetal-*.dmg)
V=${DMG#Shepetal-}; V=${V%.dmg}
BUILD=$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$A/appcast.xml")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
bad=0
r2() { local d=$1; shift; (cd "$T" && WRANGLER_SEND_METRICS=false npx --yes wrangler@4.151.3 r2 object "$@" --local --persist-to "$d" >/dev/null 2>&1); }
stage() { for f in "$DMG" "$DMG.sha256" appcast.xml; do r2 "$1" put "shepetal-releases/staging/$V/$f" --file "$2/$f"; done; }
has() { r2 "$1" get "shepetal-releases/$2" --file "$T/got"; }
same() { has "$1" "$2" && cmp -s "$T/got" "$3"; }
promote() { R2="--local --persist-to $1" scripts/mac/promote.sh "${@:2}" --unnotarized >"$T/log" 2>&1; }
ok() { echo "ok   $1"; }
refused() { echo "ok   $1: $(tail -1 "$T/log")"; }
no() { echo "FAIL $1"; sed 's/^/     | /' "$T/log"; bad=1; }
nothing_in() { ! has "$1" "releases/$V/$DMG" && ! has "$1" "releases/$V/$DMG.sha256" && ! has "$1" "releases/$V/appcast.xml"; }

# Without --unnotarized, a DMG with no notarization ticket is refused, and nothing is written.
stage "$T/r2-notary" "$A"
if R2="--local --persist-to $T/r2-notary" scripts/mac/promote.sh "$V" --latest >"$T/log" 2>&1; then no "an unnotarized DMG was promoted without --unnotarized"
elif ! grep -q "is not notarized and stapled" "$T/log"; then no "an unnotarized DMG was refused, but not by the staple check"
elif nothing_in "$T/r2-notary" && ! has "$T/r2-notary" latest.json; then refused "without --unnotarized, an unnotarized DMG is refused"
else no "an unnotarized DMG was refused, but something was written"; fi

# A .sha256 that is not the DMG's is refused.
cp -R "$A" "$T/badsum"
(cd "$T/badsum" && shasum -a 256 appcast.xml | sed "s/appcast.xml/$DMG/" > "$DMG.sha256")
stage "$T/r2-badsum" "$T/badsum"
if promote "$T/r2-badsum" "$V" --latest; then no "a wrong .sha256 was promoted"
elif ! grep -q "$DMG.sha256 is not the SHA-256 of $DMG" "$T/log"; then no "a wrong .sha256 was refused, but not by the SHA-256 check"
elif nothing_in "$T/r2-badsum" && ! has "$T/r2-badsum" latest.json; then refused "a wrong .sha256 is refused"
else no "a wrong .sha256 was refused, but something was written"; fi

# An appcast that offers the DMG at another URL (signature and length still right) is refused.
cp -R "$A" "$T/elsewhere"
sed -i '' 's|url="https://[^/"]*/|url="https://elsewhere.example/|' "$T/elsewhere/appcast.xml"
stage "$T/r2-elsewhere" "$T/elsewhere"
if promote "$T/r2-elsewhere" "$V" --latest; then no "an appcast with another enclosure URL was promoted"
elif ! grep -q "appcast.xml does not offer" "$T/log"; then no "an appcast with another enclosure URL was refused, but not by the URL check"
elif nothing_in "$T/r2-elsewhere" && ! has "$T/r2-elsewhere" latest.json; then refused "an appcast with another enclosure URL is refused"
else no "an appcast with another enclosure URL was refused, but something was written"; fi

# A DMG with one flipped byte (and a .sha256 that matches it) is refused, and nothing is written.
cp -R "$A" "$T/flipped"
python3 -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[4096] ^= 1; open(p, "wb").write(b)' "$T/flipped/$DMG"
(cd "$T/flipped" && shasum -a 256 "$DMG" > "$DMG.sha256")
stage "$T/r2-flipped" "$T/flipped"
if promote "$T/r2-flipped" "$V" --latest; then no "a flipped byte was promoted"
elif nothing_in "$T/r2-flipped" && ! has "$T/r2-flipped" latest.json; then refused "a flipped byte is refused before anything is written"
else no "a flipped byte was refused, but something was written"; fi

# The same app re-packed (other bytes; a matching .sha256 and appcast length, the old signature) mounts fine; only
# the EdDSA signature can refuse it.
cp -R "$A" "$T/repacked"
rm "$T/repacked/$DMG"
hdiutil convert "$A/$DMG" -format UDZO -o "$T/repacked/$DMG" -quiet
(cd "$T/repacked" && shasum -a 256 "$DMG" > "$DMG.sha256")
sed -i '' "s/length=\"[0-9]*\"/length=\"$(stat -f %z "$T/repacked/$DMG")\"/" "$T/repacked/appcast.xml"
stage "$T/r2-repacked" "$T/repacked"
if promote "$T/r2-repacked" "$V" --latest; then no "a re-packed DMG was promoted under the old signature"
elif ! grep -q "the signature does not match the DMG" "$T/log"; then no "a re-packed DMG was refused, but not by its signature"
elif nothing_in "$T/r2-repacked" && ! has "$T/r2-repacked" latest.json; then refused "a re-packed DMG is refused before anything is written"
else no "a re-packed DMG was refused, but something was written"; fi

# A release that is not above LATEST is refused, and LATEST stays.
stage "$T/r2-below" "$A"
printf '{"version":"9.9.9","build":%s}\n' "$((BUILD + 1))" > "$T/latest.json"
printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>9.9.9</sparkle:shortVersionString></item></channel></rss>\n' "$((BUILD + 1))" > "$T/previous.xml"
r2 "$T/r2-below" put shepetal-releases/latest.json --file "$T/latest.json"
r2 "$T/r2-below" put shepetal-releases/releases/9.9.9/appcast.xml --file "$T/previous.xml"
if promote "$T/r2-below" "$V" --latest; then no "a release below LATEST was promoted"
elif ! grep -q "release guard: version $V is not above the published 9.9.9" "$T/log"; then no "a release below LATEST was refused, but not by the release guard"
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

# Pulling a bad release: LATEST (9.9.9) points back at $V, promoted before. The "above LATEST" check is skipped only
# for releases/<v>/; a staged release below LATEST stays refused (above).
r2 "$T/r2" put shepetal-releases/latest.json --file "$T/latest.json"
r2 "$T/r2" put shepetal-releases/releases/9.9.9/appcast.xml --file "$T/previous.xml"
if ! promote "$T/r2" "$V" --latest; then no "promote $V --latest could not point LATEST back from 9.9.9"
elif same "$T/r2" latest.json "$T/want.json"; then ok "promote $V --latest points LATEST back from 9.9.9: $(cat "$T/want.json")"
else no "promote $V --latest from 9.9.9 wrote $(cat "$T/got" 2>/dev/null)"; fi

# SKIP_NOTARY never reaches the real bucket.
if SKIP_NOTARY=1 R2=--remote scripts/mac/promote.sh "$V" >"$T/log" 2>&1; then no "SKIP_NOTARY=1 ran against --remote"
elif grep -q "SKIP_NOTARY=1 is only for a local R2" "$T/log"; then refused "SKIP_NOTARY=1 is refused with --remote"
else no "SKIP_NOTARY=1 with --remote failed for another reason"; fi

[ "$bad" = 0 ] || { echo "test-promote: FAILED"; exit 1; }
echo "test-promote: ok ($DMG, build $BUILD)"
