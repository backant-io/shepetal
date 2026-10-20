#!/bin/bash
# Reproduce docs/models.md numbers on a Mac: ./bench/run.sh [engine ...]
# Everything (venv, whisper.cpp build, models) stays in bench/.venv and bench/.cache.
set -euo pipefail
cd "$(dirname "$0")"
C=.cache; mkdir -p $C results
ENGINES=${*:-"parakeet-110m moonshine-tiny wcpp-base.en-q5_1 wcpp-small"}
[ -x .venv/bin/python ] || { uv venv -q .venv --python 3.12 && VIRTUAL_ENV=$PWD/.venv uv pip install -q sherpa-onnx jiwer numpy soundfile; }
[ -f fixtures/meeting.wav ] || ./make_fixtures.sh
if [ ! -x $C/whisper.cpp/build/bin/whisper-cli ]; then
  [ -d $C/whisper.cpp ] || git clone -q --depth 1 https://github.com/ggml-org/whisper.cpp $C/whisper.cpp
  cmake -S $C/whisper.cpp -B $C/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DWHISPER_SDL2=OFF -DGGML_CCACHE=OFF >/dev/null
  cmake --build $C/whisper.cpp/build -j 8 --target whisper-cli >/dev/null
fi
S=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models
H=https://huggingface.co/ggerganov/whisper.cpp/resolve/main
for e in $ENGINES; do
  case $e in
    parakeet-110m) d=sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8 ;;
    parakeet-v3)   d=sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8 ;;
    moonshine-*)   d=sherpa-onnx-$e-en-int8 ;;
    sensevoice)    d=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17 ;;
    wcpp-*)        d= ; f=$C/ggml-${e#wcpp-}.bin; [ -f $f ] || { curl -fsSL -o $f.part "$H/ggml-${e#wcpp-}.bin" && mv $f.part $f; } ;;
    *) echo "unknown engine $e" >&2; exit 1 ;;
  esac
  # extract into .part first so an interrupted download never looks like a finished model dir
  [ -z "$d" ] || [ -d $C/$d ] || { mkdir -p $C/.part && curl -fsSL $S/$d.tar.bz2 | tar xj -C $C/.part && mv $C/.part/$d $C/; }
  .venv/bin/python bench.py $e | tee -a results/summary.jsonl
done
