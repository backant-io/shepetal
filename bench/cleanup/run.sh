#!/bin/bash
# Benchmarks local cleanup models on bench/cleanup/fixtures with the app's own code (ShepetalCleanup,
# llama.cpp with Metal). One process per model, so peak memory is per model.
#   bench/cleanup/run.sh                 the rules baseline and every model below
#   bench/cleanup/run.sh Qwen3.5-0.8B-Q4_K_M.gguf ...   only these
# Weights go to $CLEANUP_MODELS (default bench/.cache/cleanup, gitignored). A file.part younger than two
# minutes means another process is downloading it, so this script waits instead of fetching it twice.
set -euo pipefail
cd "$(dirname "$0")/../.."
MODELS=${CLEANUP_MODELS:-$PWD/bench/.cache/cleanup}
OUT=bench/cleanup/results
mkdir -p "$MODELS" "$OUT"

# file  Hugging Face repo (the models in docs/models.md, Cleanup)
CATALOG="Qwen3.5-0.8B-Q4_K_M.gguf unsloth/Qwen3.5-0.8B-GGUF
Qwen3.5-2B-Q4_K_M.gguf unsloth/Qwen3.5-2B-GGUF
LFM2.5-1.2B-Instruct-Q4_K_M.gguf LiquidAI/LFM2.5-1.2B-Instruct-GGUF
gemma-3-1b-it-Q4_K_M.gguf ggml-org/gemma-3-1b-it-GGUF
gemma-3-270m-it-Q4_K_M.gguf unsloth/gemma-3-270m-it-GGUF"

fetch() {
  local file=$1 repo
  repo=$(awk -v f="$file" '$1 == f { print $2 }' <<<"$CATALOG")
  [ -n "$repo" ] || { echo "unknown model $file" >&2; return 1; }
  while [ -f "$MODELS/$file.part" ] && [ $(( $(date +%s) - $(stat -f %m "$MODELS/$file.part") )) -lt 120 ]; do
    echo "waiting for another download of $file" >&2; sleep 30
  done
  [ -f "$MODELS/$file" ] && return 0
  curl -fL --retry 5 -C - -o "$MODELS/$file.part" "https://huggingface.co/$repo/resolve/main/$file"
  mv "$MODELS/$file.part" "$MODELS/$file"
}

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
