#!/bin/bash
# Benchmarks local cleanup models on bench/cleanup/fixtures with the app's own code (ShepetalCleanup,
# llama.cpp with Metal). One process per model, so peak memory is per model.
#   bench/cleanup/run.sh                 the rules baseline and every model below
#   bench/cleanup/run.sh Qwen3.5-0.8B-Q4_K_M.gguf ...   only these
#   bench/cleanup/run.sh --fetch Qwen3.5-2B-Q4_K_M.gguf ...   only download (scripts/e2e-mac.sh uses this)
# Weights go to $CLEANUP_MODELS (default bench/.cache/cleanup, gitignored). A file.part younger than two
# minutes means another process is downloading it, so this script waits instead of fetching it twice.
set -euo pipefail
cd "$(dirname "$0")/../.."
MODELS=${CLEANUP_MODELS:-$PWD/bench/.cache/cleanup}
OUT=bench/cleanup/results
mkdir -p "$MODELS" "$OUT"

# file  Hugging Face repo  commit  SHA-256 (the models in docs/models.md, Cleanup). Pinned to a commit, so a
# re-upload upstream cannot change what is downloaded; the file is checked before it is used.
CATALOG="Qwen3.5-0.8B-Q4_K_M.gguf unsloth/Qwen3.5-0.8B-GGUF 6ab461498e2023f6e3c1baea90a8f0fe38ab64d0 bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517
Qwen3.5-2B-Q4_K_M.gguf unsloth/Qwen3.5-2B-GGUF f6d5376be1edb4d416d56da11e5397a961aca8ae aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223
LFM2.5-1.2B-Instruct-Q4_K_M.gguf LiquidAI/LFM2.5-1.2B-Instruct-GGUF 8ed288026e23958ad9dfa92d53ed773a8eee7125 b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5
gemma-3-1b-it-Q4_K_M.gguf ggml-org/gemma-3-1b-it-GGUF f9c28bcd85737ffc5aef028638d3341d49869c27 8ccc5cd1f1b3602548715ae25a66ed73fd5dc68a210412eea643eb20eb75a135
gemma-3-270m-it-Q4_K_M.gguf unsloth/gemma-3-270m-it-GGUF c90975dbd40c0c7b275fefaae758c3415c906238 b1baabd6b729e4041822220d3e648e00d99cac5df86b10dffb77bcccf0688e39"

fetch() {
  local file=$1 repo rev sha
  read -r repo rev sha < <(awk -v f="$file" '$1 == f { print $2, $3, $4 }' <<<"$CATALOG")
  [ -n "${repo:-}" ] || { echo "unknown model $file" >&2; return 1; }
  while [ -f "$MODELS/$file.part" ] && [ $(( $(date +%s) - $(stat -f %m "$MODELS/$file.part") )) -lt 120 ]; do
    echo "waiting for another download of $file" >&2; sleep 30
  done
  if [ -f "$MODELS/$file" ]; then
    [ "$(shasum -a 256 "$MODELS/$file" | awk '{ print $1 }')" = "$sha" ] && return 0
    echo "$MODELS/$file does not match its pinned SHA-256; delete it and run again" >&2; return 1
  fi
  curl -fL --retry 5 -C - -o "$MODELS/$file.part" "https://huggingface.co/$repo/resolve/$rev/$file"
  if [ "$(shasum -a 256 "$MODELS/$file.part" | awk '{ print $1 }')" != "$sha" ]; then
    rm -f "$MODELS/$file.part"; echo "$file: download does not match its pinned SHA-256" >&2; return 1
  fi
  mv "$MODELS/$file.part" "$MODELS/$file"
}
if [ "${1:-}" = --fetch ]; then shift; for file; do fetch "$file"; done; exit 0; fi

swift build -c release --product cleanup-bench
BIN=$(swift build -c release --show-bin-path)/cleanup-bench
FIX=bench/cleanup/fixtures/dictation.jsonl

if [ $# -eq 0 ]; then
  "$BIN" rules "$FIX" > "$OUT/rules.jsonl"
  set -- $(awk '{ print $1 }' <<<"$CATALOG")
fi
for file in "$@"; do
  fetch "$file"
  "$BIN" "$MODELS/$file" "$FIX" > "$OUT/${file%.gguf}.jsonl"
done
python3 bench/cleanup/score.py
