#!/bin/bash
# Runs every test suite in the repo and stops at the first failure. Run it before every push.
#   scripts/ci/run-checks.sh              all suites, in the order below
#   scripts/ci/run-checks.sh --fast       skip the Docker suites (linux, meeting-linux) and ios
#   scripts/ci/run-checks.sh --only NAME  one suite
#   scripts/ci/run-checks.sh --self-test  check this runner (the scripts suite runs it)
# .github/workflows/ci.yml runs the same suites one by one with --only.
# scripts/e2e-mac.sh needs the 470 MB Parakeet model. Not run here; the Claims workflow runs it (docs/claims.md).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CACHE=${CI_CACHE:-$ROOT/.cache/ci}   # Docker build caches and the iOS DerivedData (gitignored)
RE=/Users/sorcecoder/shepetal-re     # extracted Wispr bundle and identifier map, only on Pavel's Mac
SUITES="swift meeting ios summarize bench scripts linux meeting-linux"
SLOW="ios linux meeting-linux"

suite_swift() { cd "$ROOT" && swift build && swift test; }

suite_meeting() { cd "$ROOT/meeting" && swift build && swift test; }

suite_ios() {
  cd "$ROOT/ios"
  xcodegen generate
  local name=${IOS_SIMULATOR:-$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]*[^ (]')}
  [ -n "$name" ] || { echo "no iPhone simulator is installed"; return 1; }
  echo "simulator: $name"
  local log=$CACHE/ios-xcodebuild.log; mkdir -p "$CACHE"
  if ! xcodebuild -scheme Shepetal -destination "platform=iOS Simulator,name=$name" \
      -derivedDataPath "$CACHE/ios" CODE_SIGNING_ALLOWED=NO build test >"$log" 2>&1; then
    grep -E ': error:|failed \(' "$log" | head -40; tail -20 "$log"; echo "full log: $log"; return 1
  fi
  grep -E 'Executed [0-9]+ tests|\*\* TEST' "$log" | tail -2
}

suite_summarize() {   # docs/summarization.md: the default path needs numpy only
  cd "$ROOT/summarize"
  [ -x .venv/bin/python ] || { python3 -m venv .venv && .venv/bin/pip install -q numpy; }
  .venv/bin/python -m unittest
}

suite_bench() { cd "$ROOT" && uv run --no-project --python 3.12 --with jiwer python bench/test_bench.py; }

suite_scripts() {
  cd "$ROOT"
  python3 scripts/parity.py
  python3 scripts/parity.py --self-test
  python3 -I scripts/extract_identifiers.py --self-test
  python3 scripts/check_re_docs.py --self-test
  python3 -I scripts/ui/gen_tokens.py --check   # Sources/Shepetal/UI/Tokens.swift is generated from design/ui/tokens.json
  python3 scripts/mac/release_guard.py --self-test   # the Mac release (docs/install-and-update.md 4)
  swift scripts/mac/verify-update.swift --self-test
  scripts/test-uninstall-script.sh
  if [ -d "$RE/asar" ]; then python3 scripts/check_re_docs.py; else python3 scripts/check_re_docs.py --no-bundle; fi
  if [ -f "$RE/identifier-map.tsv" ]; then
    python3 scripts/parity.py --completeness "$RE/identifier-map.tsv" "$RE/identifiers"
  else
    echo "SKIP parity.py --completeness: $RE/identifier-map.tsv is only on Pavel's Mac"
  fi
  scripts/ci/run-checks.sh --self-test   # last, so it fails the suite even if set -e is lost
}

suite_linux() {   # the command from linux/README.md, plus cache mounts
  [ -d "$ROOT/linux" ] || { echo "linux/: not on this branch"; return 0; }
  mkdir -p "$CACHE/cargo-registry" "$CACHE/linux-target"
  docker run --rm -v "$ROOT":/src -w /src/linux -e CARGO_TARGET_DIR=/target \
    -v "$CACHE/cargo-registry":/root/.cargo/registry -v "$CACHE/linux-target":/target ubuntu:24.04 sh -c \
    'apt-get update -qq && apt-get install -y -qq cargo >/dev/null && cargo test && cargo build --release && /target/release/shepetal probe --pw-dump fixtures/pw-dump-meeting.json'
}

suite_meeting-linux() {   # MeetingCore only: MeetingMac and the CLI are behind canImport(CoreAudio)
  mkdir -p "$CACHE/meeting-linux"
  docker run --rm -v "$ROOT/meeting":/w -w /w -v "$CACHE/meeting-linux":/build swift:6.2 swift test --scratch-path /build
}

run_suites() {   # stops at the first failing suite with exit 1
  local start=$SECONDS s t rc
  for s in "$@"; do
    if [ -n "$fast" ] && [[ " $SLOW " == *" $s "* ]]; then echo "== $s: SKIP (--fast)"; continue; fi
    echo "== $s"
    t=$SECONDS
    ( set -ex; "suite_$s" ); rc=$?
    if [ $rc -ne 0 ]; then echo "== FAIL: $s (exit $rc). Fix it, then rerun: $0 --only $s"; exit 1; fi
    echo "== $s: ok ($((SECONDS - t)) s)"
  done
  echo "== passed: ${only:-all suites}${fast:+ except $SLOW} ($((SECONDS - start)) s). Not run: scripts/e2e-mac.sh (needs the Parakeet model)"
}

self_test() {   # CI can only go red if a failing command inside a suite fails the run
  suite_selftest_fail() { true; false; true; }
  suite_selftest_pass() { echo selftest_pass ran; }
  local out rc s bad=
  out=$(run_suites selftest_fail selftest_pass 2>&1); rc=$?
  [ $rc -eq 1 ] || { echo "self-test: a suite whose middle command fails exited $rc, want 1"; bad=1; }
  [[ $out != *"selftest_pass ran"* ]] || { echo "self-test: the suite after a failing one still ran"; bad=1; }
  out=$(run_suites selftest_pass 2>&1); rc=$?
  [ $rc -eq 0 ] || { echo "self-test: a passing suite exited $rc, want 0"; bad=1; }
  for s in $SUITES; do   # every suite must have its own CI step
    grep -qE "run-checks\.sh --only $s\$" "$ROOT/.github/workflows/ci.yml" ||
      { echo "self-test: .github/workflows/ci.yml has no 'run-checks.sh --only $s' step"; bad=1; }
  done
  [ -z "$bad" ] || exit 1
  echo "self-test ok"
}

fast= only=
while [ $# -gt 0 ]; do
  case $1 in
    --fast) fast=1 ;;
    --only) only=${2:?--only needs a suite name}; shift ;;
    --self-test) self_test; exit 0 ;;
    *) echo "usage: $0 [--fast] [--only SUITE] [--self-test]  (suites: $SUITES)"; exit 2 ;;
  esac
  shift
done
if [ -n "$only" ] && [[ " $SUITES " != *" $only "* ]]; then echo "unknown suite '$only' (suites: $SUITES)"; exit 2; fi

run_suites ${only:-$SUITES}
