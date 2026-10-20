# Speech-to-text models for shepetal

Status: October 2026. Rows marked **measured** were run on an Apple M4 Pro (24 GB, macOS 15) with
`bench/run.sh`. Rows marked **research** come from model cards and vendor benchmarks (links at the end)
and were not run here.

## Measured on this Mac

Fixtures: 8 dictation utterances (5.7 to 9.2 s each: technical words, numbers and money, a self-correction)
and one 57 s two-voice meeting, all synthesized with macOS `say` (Samantha, Daniel) at 16 kHz mono.
The reference text sits next to each WAV in `bench/fixtures/`.

| Engine (runtime, quant) | Model size | Peak RAM | WER dictation | WER meeting | Time to text after end of audio (dictation mean) | Meeting (57 s) decode | RTF | Status |
|---|---|---|---|---|---|---|---|---|
| Parakeet TDT-CTC 110M EN (sherpa-onnx CPU, int8) | 126 MB | 767 MB | 15.7 % (no ITN, see notes) | 3.7 % | **66 ms** | 0.71 s | **0.011** | measured |
| Moonshine tiny EN (sherpa-onnx CPU, int8) | 119 MB | 877 MB | 12.0 % | 89.5 % (no VAD, see notes) | 91 ms | 2.00 s | 0.024 | measured |
| Whisper base.en (whisper.cpp Metal, q5_1) | 57 MB | 287 MB | 3.6 % | 0.0 % | 176 ms | 1.02 s | 0.021 | measured |
| Whisper small (whisper.cpp Metal, f16) | 465 MB | 825 MB | 3.6 % | 0.6 % | 413 ms | 1.57 s | 0.043 | measured |

How to read it:

- **Time to text after end of audio** is the wall time from "the whole utterance is in memory" to "text is
  back", with the model already loaded and warmed up. That is the delay a push-to-talk user feels.
  RTF is that time divided by the audio length (lower is better).
- **Peak RAM** is the max RSS of the benchmark process, including about 40 MB for Python. For whisper.cpp it
  is the `whisper-cli` child process. Metal buffers are counted in RSS on Apple Silicon.
- **WER** uses lowercase, no punctuation, and "two" equals "2". With 8 short TTS clips, one wrong word moves
  the dictation WER by about 0.9 points. The errors are the interesting part:
  - Every model wrote `useEffect` as "use effect". This is a case for a custom-vocabulary step.
  - Whisper turned "4,250 dollars and 75 cents" into "$4,250.75". That is the right output for dictation,
    but WER counts it as wrong.
  - Whisper small heard "Parakeet" as "perrapeet". Product names need hotword biasing.
  - Parakeet 110M (CTC head) outputs spoken-form numbers ("four thousand two hundred and fifty") and has no
    ITN. About half of its 15.7 % is number formatting. The rest are real errors on technical words:
    "graph QL", "post g's" for Postgres, "redisk", "JSO and". sherpa-onnx can add ITN through FST rules.
  - Moonshine tiny is only reliable on short segments. Given the whole 57 s meeting in one call, it dropped
    most of it (89.5 % WER), so it needs VAD segmentation in front. On dictation it confused "no wait" with
    "no way" and "Kubernetes" with "qber needs".
  - The sherpa-onnx rows reach 770 to 880 MB peak RSS even though the models are 120 MB. Most of that is the
    onnxruntime memory arena growing on the 57 s meeting. Time to text for these two is CPU-only (4 threads).
    whisper.cpp uses the M4 Pro GPU through Metal.
- Synthetic voices are cleaner than a real microphone, so real-world WER will be higher for every model.
  Use these numbers to compare models, not as absolute values.
- Per-file transcripts are in `bench/results/<engine>.json`.

Skipped in this sprint: Parakeet TDT 0.6B v3 (sherpa-onnx int8, 640 MB) and the FluidAudio and WhisperKit
CoreML builds. The shared network gave about 0.5 MB/s, so the 0.6B weights could not download in the time
box. `./bench/run.sh parakeet-v3` runs it when the bandwidth allows. The FluidAudio and WhisperKit Swift
CLIs are not in the harness yet.

## Candidates (research)

| Model | Params / disk | Languages | Streaming | Word timestamps | Custom vocab / hotwords | Runtimes | Published WER |
|---|---|---|---|---|---|---|---|
| **Parakeet TDT 0.6B v3** (NVIDIA, CC-BY-4.0) | 600M; ~640 MB int8 ONNX | 25 European | No (batch; FluidAudio uses chunks) | Yes | FluidAudio: yes, through a CTC 110M keyword spotter, batch only. sherpa-onnx: not verified | FluidAudio CoreML/ANE, sherpa-onnx, NeMo | Open ASR avg 6.34, LS-clean 1.93; FluidAudio reports ~110 to 155x real time on M4 Pro |
| Parakeet TDT 0.6B v2 | 600M | English | No | Yes | as v3 | as v3 | avg 6.05, LS-clean 1.69 |
| Parakeet realtime EOU 120M | 120M | English | **True streaming** (80 to 160 ms chunks, end-of-utterance token) | n/a | No | FluidAudio, NeMo | avg 9.30 at 160 ms. No punctuation or casing |
| Nemotron Speech Streaming EN 0.6B | 600M | English | **True streaming** (cache-aware RNNT, 80 to 1120 ms) | n/a | n/a | FluidAudio, sherpa-onnx, NeMo | avg 6.93 at 1120 ms, 8.43 at 80 ms. Has punctuation and casing |
| Nemotron 3.5 ASR Streaming 0.6B (June 2026) | 600M | 40 locales + language ID | **True streaming** | n/a | n/a | sherpa-onnx, NeMo | not checked. CPU and Apple speed not verified |
| Whisper large-v3-turbo | 809M; ~550 MB q5_0, ~630 MB CoreML | 99 | Chunked only | Yes (experimental in whisper.cpp) | Prompt only (WhisperKit: Pro SDK) | whisper.cpp (Metal, CUDA, Vulkan, HIP, CPU), WhisperKit (CoreML/ANE) | avg ~7.8 (not verified) |
| Whisper small / base.en | 244M / 74M | 99 / English | Chunked only | Yes | Prompt only | as above | see measured table |
| Moonshine v1 tiny / base | 27M / 61M | English | No | n/a | No | sherpa-onnx, ONNX | not on the model card |
| Moonshine Streaming (tiny, small, medium) | 34M / 123M / 245M | English | **True streaming** | No | No | transformers, GGUF ports | avg 12.0 / 7.8 / 6.7 |
| SenseVoice Small | ~230 MB int8 | zh, en, yue, ja, ko | No | n/a | No | sherpa-onnx, FunASR, FluidAudio | ~70 ms per 10 s of audio |
| Canary-1B-flash / Canary-1B-v2 | 883M | en, de, fr, es / 25 EU | No | Experimental | n/a | NeMo (GPU) | avg 6.35 |
| Canary-Qwen-2.5B | 2.5B | English | No (40 s max) | n/a | n/a | NeMo (GPU) | avg 5.63 (best on the board, too big for local dictation) |
| Kyutai STT 1B en/fr, 2.6B en | 1B / 2.6B | en+fr / en | **True streaming** (0.5 s / 2.5 s delay) | Yes | n/a | PyTorch, MLX | not on the card |
| Voxtral Mini 4B Realtime | 4B | 13 | **True streaming** | n/a | n/a | vLLM on a 16 GB+ GPU | FLEURS 8.7 at 480 ms |

## Tier table

| Device class | Default | Fallback | Why | Status |
|---|---|---|---|---|
| Apple Silicon, 8 GB | Parakeet TDT 0.6B v3, FluidAudio CoreML on the ANE | Whisper base.en q5_1, whisper.cpp Metal (57 MB, 287 MB RAM, 176 ms) | The ANE keeps the GPU and CPU free. base.en is the smallest model that still scored 3.6 % here | default: research; fallback: measured |
| Apple Silicon, 16 GB | Parakeet TDT 0.6B v3 (FluidAudio) + custom vocabulary | Whisper large-v3-turbo q5_0 (whisper.cpp Metal or WhisperKit) for languages Parakeet does not cover | Parakeet has the best accuracy per watt for the 25 EU languages. Turbo covers 99 languages | research (Whisper small measured: 825 MB, 413 ms) |
| Apple Silicon, 24 GB+ | Parakeet TDT 0.6B v3 (FluidAudio) + custom vocabulary + diarizer | WhisperKit large-v3-turbo | There is RAM to keep ASR, the diarizer and a local LLM cleanup model loaded together | research |
| iPhone, A15 (4 to 6 GB) | Parakeet TDT 0.6B v3 CoreML (FluidAudio needs iOS 17+), run in the host app | WhisperKit base.en / tiny | A keyboard extension has a small memory limit (about 60 MB, not verified), so ASR has to run in the app, not in the keyboard. Not verified on 4 GB phones | research |
| iPhone, A16 / A17 Pro (6 to 8 GB) | Parakeet TDT 0.6B v3 (FluidAudio) | WhisperKit small | | research |
| iPhone, A18 / A19 (8 GB+) | Parakeet TDT 0.6B v3 (FluidAudio) + custom vocabulary | WhisperKit large-v3-turbo (626 MB) | | research |
| Linux CPU only, x86 / ARM | Parakeet TDT 0.6B v3 int8, sherpa-onnx | Parakeet TDT-CTC 110M int8 (sherpa-onnx, 66 ms, 0.011 RTF on CPU) for low-end ARM such as a Raspberry Pi. Moonshine tiny only behind VAD | Same model family as the Mac, one ONNX runtime, no GPU needed | fallbacks: measured on M4 Pro CPU; default: research |
| Linux NVIDIA CUDA | Parakeet TDT 0.6B v3 (sherpa-onnx CUDA provider or NeMo) | Whisper large-v3-turbo, whisper.cpp CUDA (99 languages) | Parakeet runs at thousands of times real time on a GPU, which is enough headroom for diarization next to it | research |
| Linux AMD / Intel Vulkan | Whisper large-v3-turbo q5_0, whisper.cpp Vulkan | Parakeet TDT 0.6B v3 int8 on CPU (sherpa-onnx) | whisper.cpp is the only runtime here with mature Vulkan support (and HIP for AMD) | research |

### Streaming model for live meeting transcripts

- **Apple:** Nemotron Speech Streaming EN 0.6B through FluidAudio (has punctuation and casing, 560 to 1120 ms
  chunks). For partial text with the lowest delay and an end-of-turn signal, use Parakeet realtime EOU 120M,
  which outputs no punctuation. After the meeting, run Parakeet TDT v3 over the whole recording as the final
  transcript.
- **Linux:** Nemotron Speech Streaming EN through sherpa-onnx. For non-English meetings use Nemotron 3.5 ASR
  Streaming (40 locales), but its CPU speed is not verified. Streaming Zipformer (sherpa-onnx, ~20M) is the
  low-end CPU fallback.
- None of these was measured in this sprint.

### Diarization candidates (research)

| Candidate | Runs on | Accuracy | License / notes |
|---|---|---|---|
| FluidAudio offline diarizer (pyannote community-1 on CoreML) | Mac, iPhone | AMI-SDM 10.6 % DER, VoxConverse 13.9 to 15.1 % (FluidAudio's numbers). Its streaming modes are much worse (21 to 56 % DER) | Apache-2.0 SDK. Best fit for Apple |
| pyannote speaker-diarization-community-1 | Linux CUDA or CPU (PyTorch) | AMI-SDM 19.9 % vs 22.7 % for 3.1; better on 10 of 12 benchmarks | CC-BY-4.0, gated on Hugging Face |
| sherpa-onnx speaker diarization (pyannote-segmentation-3.0 + 3D-Speaker or TitaNet embeddings) | Linux CPU, any ONNX target | no published DER | Tiny (5.7 MB segmentation). The reverb-diarization-v1 option is non-commercial |

Do diarization offline (after the meeting or over a sliding window of tens of seconds). Every streaming
diarizer above loses a lot of accuracy.

## Reproduce

```bash
./bench/run.sh                                   # default engines from the measured table
./bench/run.sh parakeet-v3 wcpp-large-v3-turbo-q5_0  # bigger models when the bandwidth allows
```

`run.sh` creates `bench/.venv` (uv, sherpa-onnx, jiwer), builds `whisper-cli` in `bench/.cache/whisper.cpp`,
downloads models to `bench/.cache`, regenerates fixtures if they are missing, and appends one JSON line per
engine to `bench/results/summary.jsonl`. Weights and the venv are gitignored.

## Sources

- https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 , https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- https://github.com/FluidInference/FluidAudio , https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md , https://docs.fluidinference.com/asr/custom-vocabulary
- https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1 , https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b , https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- https://github.com/argmaxinc/WhisperKit , https://github.com/ggml-org/whisper.cpp
- https://k2-fsa.github.io/sherpa/onnx/hotwords/index.html (hotwords work only with transducer models and modified_beam_search)
- https://huggingface.co/moonshine-ai/moonshine-streaming-tiny , https://huggingface.co/nvidia/canary-1b-flash , https://huggingface.co/nvidia/canary-qwen-2.5b
- https://huggingface.co/kyutai/stt-1b-en_fr , https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602
- https://huggingface.co/pyannote/speaker-diarization-community-1
