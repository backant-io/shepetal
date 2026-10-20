#!/bin/bash
# Uninstalls Shepetal: quits it, turns Start at login off, puts back the "Press 🌐 key to" setting it
# replaced, and removes /Applications/Shepetal.app (and an old ~/Applications copy).
# Your recordings and history in ~/Library/Application Support/Shepetal are KEPT unless you pass
# --delete-data. Also shipped inside the app: /Applications/Shepetal.app/Contents/Resources/uninstall.sh
#
#   uninstall-mac.sh [--delete-data] [--dry-run]
set -uo pipefail
DELETE_DATA=0; DRY=0
for a in "$@"; do
  case $a in
    --delete-data) DELETE_DATA=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
do_() { if [ "$DRY" = 1 ]; then echo "dry-run: $*"; else "$@"; fi; }

APPS=()
for a in "${SHEPETAL_APPS_DIR:-/Applications}/Shepetal.app" "$HOME/Applications/Shepetal.app"; do [ -d "$a" ] && APPS+=("$a"); done

if pgrep -qx Shepetal; then
  do_ osascript -e 'quit app "Shepetal"' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do [ "$DRY" = 1 ] || ! pgrep -qx Shepetal && break; sleep 0.25; done
fi

# Start at login off, while the app is still there to ask.
for a in ${APPS[@]+"${APPS[@]}"}; do do_ "$a/Contents/MacOS/Shepetal" --unregister-login-item; done

# The 🌐 key: put back what Shepetal replaced (-1: the key was absent).
PREV=$(defaults read io.backant.shepetal previousAppleFnUsageType 2>/dev/null) || PREV=
if [ -n "$PREV" ]; then
  if [ "$PREV" = -1 ]; then do_ defaults delete com.apple.HIToolbox AppleFnUsageType
  else do_ defaults write com.apple.HIToolbox AppleFnUsageType -int "$PREV"; fi
  do_ killall TextInputMenuAgent 2>/dev/null
  do_ killall -9 TextInputSwitcher 2>/dev/null
  do_ defaults delete io.backant.shepetal previousAppleFnUsageType
  echo "🌐 key setting restored (AppleFnUsageType ${PREV/-1/unset})"
else
  echo "🌐 key setting left as it is (Shepetal did not change it)"
fi

for a in ${APPS[@]+"${APPS[@]}"}; do do_ rm -rf "$a" && [ "$DRY" = 0 ] && echo "Removed $a"; done
if pkgutil --pkgs 2>/dev/null | grep -qx io.backant.shepetal.pkg; then
  echo "The installer receipt stays (removing it needs admin rights: sudo pkgutil --forget io.backant.shepetal.pkg)"
fi

DATA="$HOME/Library/Application Support/Shepetal"
if [ "$DELETE_DATA" = 1 ]; then
  do_ rm -rf "$DATA" && [ "$DRY" = 0 ] && echo "Deleted $DATA"
  do_ defaults delete io.backant.shepetal 2>/dev/null
else
  [ -d "$DATA" ] && echo "Kept your recordings and history in $DATA (pass --delete-data to remove them)"
fi
[ "$DRY" = 1 ] && echo "Dry run: nothing was changed." || echo "Shepetal is uninstalled."
