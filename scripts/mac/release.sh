#!/bin/bash
# The Mac release (docs/install-and-update.md 4): guard → build and sign with the hardened runtime → DMG → notarize →
# staple → Sparkle appcast (generate_appcast) → check the appcast against the key inside the built app. It never
# publishes anything: .github/workflows/mac-release.yml makes a DRAFT release from dist/, and Pavel publishes it.
#
#   TAG=v0.2.0-mac scripts/mac/release.sh   the release (CI on a v*-mac tag, or Pavel by hand on main)
#   scripts/mac/release.sh --dry-run        everything that needs no credential; VERSION defaults to 0.0.0
#
# Credentials, from the environment (CI) or this Mac's login Keychain. A missing one makes it a dry run that says
# what it skipped; dist/release.env then says MODE=dry-run and the workflow makes no draft.
#   Developer ID   SIGN_IDENTITY, or the first "Developer ID Application" identity in the keychain
#   notarytool     NOTARY_KEY_FILE + NOTARY_KEY_ID + NOTARY_ISSUER_ID, or the keychain profile shepetal-notary
#                  (NOTARY_PROFILE overrides the name)
#   Sparkle        SPARKLE_KEY_FILE (generate_keys -x format), or the private key in the login Keychain
set -euo pipefail
cd "$(dirname "$0")/../.."
DRY_RUN=0; [ "${1:-}" = --dry-run ] && DRY_RUN=1
SKIPPED=()
skip() { SKIPPED+=("$1"); echo "DRY RUN: $1" >&2; }
[ "$DRY_RUN" = 1 ] && skip "--dry-run: no credential is used"
W=.cache/release
rm -rf "$W"; mkdir -p "$W" dist

# 1. The guard: tag format, a full clone, on main, version and build above the newest published Mac release.
TAG=${TAG:-v${VERSION:-0.0.0}-mac}
BUILD=$(git rev-list --count HEAD)
GUARD=(--tag "$TAG" --build "$BUILD")
if [ "$DRY_RUN" = 1 ]; then
  GUARD+=(--main "")
else
  PREV=$(gh release list --limit 100 --json tagName,isDraft,isPrerelease --jq \
    '[.[] | select((.isDraft or .isPrerelease) | not) | select(.tagName | test("^v[0-9]+\\.[0-9]+\\.[0-9]+-mac$"))][0].tagName // ""')
  if [ -n "$PREV" ]; then
    gh release download "$PREV" --pattern appcast.xml --dir "$W/previous"
    GUARD+=(--previous "$W/previous/appcast.xml")
  fi
fi
export VERSION; VERSION=$(python3 scripts/mac/release_guard.py "${GUARD[@]}")
echo "Release $VERSION, build $BUILD"

# 2. Build and sign. A Developer ID build must have the pinned designated requirement, or users lose their permissions.
ID=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Developer ID Application/ && !n++ { print $2 }')}
[ "$DRY_RUN" = 1 ] && ID=
if [ -n "$ID" ]; then
  export SIGN_IDENTITY=$ID TIMESTAMP=1 EXPECT_DR=scripts/mac/designated-requirement.txt
else
  [ "$DRY_RUN" = 1 ] || skip "no Developer ID Application identity: signed with whatever make-app.sh finds, not notarized"
fi
# The Sparkle key. Without the real one, the app and the appcast get a throwaway key, so the whole chain still runs
# (generate_appcast refuses to sign for a key the app does not carry); that DMG can never update and is never released.
SPARKLE=.build/artifacts/sparkle/Sparkle/bin
KEY=()
unset SPARKLE_PUBLIC_KEY  # a release carries the key committed in make-app.sh
if [ "$DRY_RUN" = 0 ] && [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
elif [ "$DRY_RUN" = 0 ] && "$SPARKLE/generate_keys" -p >/dev/null 2>&1; then
  :  # generate_appcast reads the login Keychain
else
  export SPARKLE_PUBLIC_KEY; SPARKLE_PUBLIC_KEY=$(swift scripts/mac/verify-update.swift --throwaway-key "$W/throwaway.key")
  KEY=(--ed-key-file "$W/throwaway.key")
  skip "Sparkle signing with a throwaway key, in the app and the appcast: this DMG can never update"
fi

scripts/make-dmg.sh
DMG=dist/Shepetal-$VERSION.dmg
APP=dist/Shepetal.app

# 3. Notarize the DMG (that covers the app inside), staple it, and check it the way Gatekeeper will.
NOTARY=()
if [ -n "${NOTARY_KEY_FILE:-}" ]; then
  NOTARY=(--key "$NOTARY_KEY_FILE" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
elif [ "$DRY_RUN" = 0 ] && xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-shepetal-notary}" >/dev/null 2>&1; then
  NOTARY=(--keychain-profile "${NOTARY_PROFILE:-shepetal-notary}")
fi
if [ -n "$ID" ] && [ ${#NOTARY[@]} -gt 0 ]; then
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --output-format json > "$W/notary.json"
  if [ "$(plutil -extract status raw "$W/notary.json")" != Accepted ]; then
    xcrun notarytool log "$(plutil -extract id raw "$W/notary.json")" "${NOTARY[@]}" >&2 || true
    echo "Notarization was refused (log above)" >&2; exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$W/mnt" "$DMG" >/dev/null
  trap 'hdiutil detach -quiet "$W/mnt" 2>/dev/null || true' EXIT
  spctl -a -vv -t exec "$W/mnt/Shepetal.app"
  hdiutil detach -quiet "$W/mnt"
  (cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")  # stapling changed the file
elif [ "$DRY_RUN" = 0 ]; then
  skip "notarization and stapling (no Developer ID identity or no notarytool credentials)"
fi

# 4. The appcast, signed AFTER stapling (stapling changes the file), then checked against the key inside the app.
mkdir -p "$W/archives"; rm -f dist/appcast.xml  # one item: this release
cp "$DMG" "$W/archives/"
"$SPARKLE/generate_appcast" ${KEY[@]+"${KEY[@]}"} --maximum-deltas 0 \
  --download-url-prefix "https://github.com/backant-io/shepetal/releases/download/$TAG/" -o dist/appcast.xml "$W/archives"
swift scripts/mac/verify-update.swift dist/appcast.xml "$DMG" "$APP/Contents/Info.plist"
grep -q "<sparkle:version>$BUILD</sparkle:version>" dist/appcast.xml || { echo "appcast.xml is not for build $BUILD" >&2; exit 1; }

MODE=release; [ ${#SKIPPED[@]} -eq 0 ] || MODE=dry-run
printf 'MODE=%s\nTAG=%s\nVERSION=%s\nBUILD=%s\n' "$MODE" "$TAG" "$VERSION" "$BUILD" > dist/release.env
echo "== $MODE: $DMG, dist/appcast.xml (build $BUILD)"
for s in ${SKIPPED[@]+"${SKIPPED[@]}"}; do echo "   skipped: $s"; done
