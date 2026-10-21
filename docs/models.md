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
| **Parakeet TDT 0.6B v3** (FluidAudio 0.17.7 CoreML, ANE, default encoder) `fluid-parakeet-v3` | 461 MB | 133 MB + ANE (see notes) | 7.2 % (no ITN, see notes) | 0.0 % | **62 ms** | 0.28 s | **0.007** | measured |
| Parakeet TDT 0.6B v3 (FluidAudio as above + its NeMo ITN) `fluid-parakeet-v3-itn` | 461 MB | 109 MB + ANE | 5.4 % | 1.2 % | 108 ms | 0.56 s | 0.013 | measured |
| Parakeet TDT 0.6B v3 (FluidAudio as above + personal dictionary rescoring with the CTC 110M keyword model, F39) `fluid-parakeet-v3-boost` | 461 MB + 99 MB | 129 MB + ANE | 4.8 % | 0.0 % | 249 ms | 1.13 s | 0.028 | measured |
| Parakeet TDT 0.6B v3 (FluidAudio CoreML, opt-in int8-v2 encoder) `fluid-parakeet-v3-int8-v2` | 603 MB | 661 MB | 7.8 % | 0.0 % | 69 ms | 0.30 s | 0.008 | measured |
| Parakeet TDT 0.6B v3 (sherpa-onnx CPU, int8) `parakeet-v3` | 640 MB | 1,844 MB | 3.6 % | 0.6 % | 177 ms | 1.46 s | 0.025 | measured |
| Parakeet TDT-CTC 110M EN (sherpa-onnx CPU, int8) `parakeet-110m` | 126 MB | 737 MB | 15.7 % (no ITN, see notes) | 3.7 % | 71 ms | 0.73 s | 0.011 | measured |
| Moonshine tiny EN (sherpa-onnx CPU, int8) `moonshine-tiny` | 119 MB | 863 MB | 12.0 % | 89.5 % (no VAD, see notes) | 64 ms | 1.79 s | 0.020 | measured |
| Whisper base.en (whisper.cpp Metal, q5_1) `wcpp-base.en-q5_1` | 57 MB | 308 MB | 3.6 % | 0.0 % | 154 ms | 0.60 s | 0.016 | measured |
| Whisper small (whisper.cpp Metal, f16) `wcpp-small` | 465 MB | 875 MB | 3.6 % | 0.6 % | 399 ms | 1.29 s | 0.039 | measured |

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
  - The sherpa-onnx rows reach 740 to 860 MB peak RSS even though the models are 120 MB. Most of that is the
    onnxruntime memory arena growing on the 57 s meeting. Time to text for these two is CPU-only (4 threads).
    whisper.cpp uses the M4 Pro GPU through Metal.
- **Parakeet TDT 0.6B v3** (the default in the tier table):
  - The goal asks the default on this Mac for WER ≤ 8 % and text ≤ 700 ms after release for a 10 s utterance.
    FluidAudio with its default encoder gives 7.2 % and 69 ms on the longest clip (d03, 9.2 s), so it passes, but
    with little WER margin (12 wrong words out of 166). With FluidAudio's ITN on top it is 5.4 %, 275 ms worst
    case. An earlier run of the default (the first `fluid-parakeet-v3` line in `results/summary.jsonl`) gave the
    same WER, 77 ms mean and 97 MB RSS.
  - Same model, two runtimes, different text. FluidAudio wrote numbers as words ("four thousand two hundred
    fifty dollars and seventy five cents", "march fifteenth"): 8 of its 12 errors are that one money clip.
    sherpa-onnx int8 wrote "$4,250.75" and "March 15" like Whisper. FluidAudio also heard Postgres as
    "PostGer's" and Redis as "redisc", which sherpa-onnx got right. sherpa-onnx heard "Parakeet" as "paracet"
    in the meeting.
  - FluidAudio's ITN (`TextNormalizer.normalizeSentence`, NeMo rules, linked by default) fixed the money
    clip but dropped the "a" in "with a 2 percent discount" and wrote "First item" as "1st item". Use it, and
    keep the dictation fixtures as its regression test.
  - Dictionary boosting (F39, #30), `fluid-parakeet-v3-boost`: FluidAudio's `VocabularyBoostingSession` with the CTC 110M
    keyword model (`parakeet-ctc-110m-coreml`, 99 MB) rescores Parakeet's text against the dictionary on the same audio.
    With 12 terms (`BOOST` in `bench/bench.py`: 9 fixture words and 3 never spoken) it wrote Postgres, useEffect and Redis
    in d02, d05 and d07, which plain Parakeet wrote as "PostGer's", "use effect" and "redisc", and changed nothing else:
    dictation WER 7.2 % to 4.8 %, meeting 0.0 % both. It costs about 120 to 190 ms per dictation (185 and 249 ms mean
    over two runs, against 66 and 64 ms for the plain engine in the same session; 261 ms on d03, the longest clip) and
    0.8 s on the 57 s meeting. With FluidAudio's defaults (similarity floor 0.52, acoustic-only rescue on), the same
    dictionary also wrote "edits" as "Redis", "percent" as "Vercel", "ready" as "React" and "error" as "Terraform"
    (6.0 %, meeting 1.2 %). A floor of 0.6 still wrote "edits" as "Redis", and 0.8 missed Postgres. With the rescue
    on and only `dentist` in the dictionary, `scripts/e2e-mac.sh` got "copy the dentist on the thread" for "copy the
    finance lead". The app and the bench use a floor of 0.7 and no rescue (`KeywordBooster.minSimilarity` and
    `KeywordBooster.config` in `Sources/Shepetal/Speech.swift`). With the keyword model, `scripts/e2e-mac.sh` passes
    offline at the same 3.1 % WER, ready in 249 to 376 ms. These settings were tuned on 8 synthetic clips only, so
    check them again on real voices.
  - The keyword model is English only. On 13 `say` clips in German, French, Spanish and Italian (voices Anna, Eddy and
    Alice; the same 12 terms, the bench's own text), it fixed "reddis a postgress", "Postgre" and "redes apóstolas" for
    Redis and Postgres, left 9 clips alone, and wrote "Las redes sociales están llenas de ruido" as "Las Redis
    sociales". So the app boosts only dictations that Apple's `NLLanguageRecognizer` does not put in another language
    with 0.9 or more (`KeywordBooster.knowsTheLanguage`). Parakeet's text for the 8 dictation fixtures and the meeting
    scores 0.95 to 1.00 English, so they stay boosted, as do one-word dictations, which the recognizer cannot place
    ("Redis." 0.52 French, "Postgres." 0.20 German). For the 13 clips it scores 0.97 to 1.00 in their own language, so
    they keep Parakeet's text and skip the boost, which cost about 100 ms on them (44 ms mean plain, 147 ms boosted).
  - FluidAudio's opt-in `int8-v2` encoder (`ParakeetEncoderPrecision.int8V2` in FluidAudio's
    `Sources/FluidAudio/ModelNames.swift`, a re-quantized rebuild of the default 6-bit palettized encoder) was
    not better here: 7.8 %, the same word errors plus one, 142 MB more on disk and 661 MB RSS. Keep the default encoder.
  - Peak RAM for the FluidAudio rows is the `fluid-bench` process. Model weights that live on the ANE are mostly
    outside RSS, so the real footprint is higher than 133 MB. Load time (0.1 to 0.7 s) is with CoreML's compiled
    cache warm; the first load right after the download, which compiles for the ANE, was not timed.
  - sherpa-onnx int8 is the most accurate run on these fixtures, but it runs on the CPU at 177 ms and peaks at
    1.8 GB RSS (onnxruntime arena on the 57 s meeting). That fits the Linux CPU tier, not an 8 GB Mac.
  - `model_mb` in `results/summary.jsonl` counts FluidAudio's whole model folder, so rows run after the
    int8-v2 encoder was downloaded show 1,029 MB. The table above gives each build's own size.
- Synthetic voices are cleaner than a real microphone, so real-world WER will be higher for every model.
  Use these numbers to compare models, not as absolute values.
- Each row is the latest run of the engine in backticks: its last line in `bench/results/summary.jsonl`, whose
  WER and latency `bench/test_bench.py` recomputes from the per-file transcripts and timings in
  `bench/results/<engine>.json`. `summary.jsonl` keeps every run. The two engines that ran twice there
  (`wcpp-base.en-q5_1`, `fluid-parakeet-v3`) gave the same WER both times, but the dictation mean moved by up
  to 20 %, the meeting decode by up to 30 % and peak RSS by up to 37 %. Treat gaps of that size between rows as
  run-to-run noise, not a ranking.

Not measured yet: WhisperKit (no Swift CLI in the harness), Whisper large-v3-turbo, the streaming models and
the diarizers. All rows ran on one M4 Pro; no other Mac, iPhone or Linux machine was measured.

### End to end in the Mac app (Parakeet v3, FluidAudio)

`scripts/e2e-mac.sh` runs the app's own pipeline on 6 `say` clips (4.5 to 10.7 s, 127 words): capture resampler,
Parakeet TDT 0.6B v3, cleanup, kept audio and history, then clipboard plus Cmd+V into a text view the app owns.
Run on 2026-10-20 at `36f3e0d` (branch `feat/mac-mac-shell-tests`) from a clean clone, release build, with the
network denied by `sandbox-exec`:

| Clip | Audio | Word errors | Text ready after release |
|---|---|---|---|
| e01 | 6.2 s | 0 / 20 | 72 ms |
| e02 | 5.4 s | 0 / 15 | 57 ms |
| e03 | 4.5 s | 0 / 17 | 63 ms |
| e04 | 6.6 s | 0 / 21 | 63 ms |
| e05 | 10.7 s | 0 / 36 | 89 ms |
| e06 | 5.8 s | 0 / 18 | 69 ms |

- WER 0.0 % over 127 words, text ready 57 to 89 ms (mean 69 ms). The goal bar is WER ≤ 8 % and ≤ 700 ms for a 10 s
  utterance; the 10.7 s clip took 89 ms. The earlier run on `982e547` gave 0.0 % and 58 to 78 ms.
- These clips are easier than the bench fixtures above (no numbers, no product names), so the 0.0 % here and the
  7.2 % above do not disagree.
- Model load was 380 ms with CoreML's compiled cache warm. A second process right after it (the silent-WAV run)
  took 38 s to load while the machine had a load average of about 45 from parallel builds. Cold and contended
  load times are not measured yet (#17).

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
| Apple Silicon, 8 GB | Parakeet TDT 0.6B v3, FluidAudio CoreML on the ANE | Whisper base.en q5_1, whisper.cpp Metal (57 MB, 308 MB RAM, 154 ms) | The ANE keeps the GPU and CPU free. base.en is the smallest model that still scored 3.6 % here | default: measured, on the M4 Pro 24 GB, not on an 8 GB Mac (461 MB on disk, 7.2 % / 5.4 % with ITN, 62 ms); fallback: measured |
| Apple Silicon, 16 GB | Parakeet TDT 0.6B v3 (FluidAudio) + custom vocabulary | Whisper large-v3-turbo q5_0 (whisper.cpp Metal or WhisperKit) for languages Parakeet does not cover | Parakeet has the best accuracy per watt for the 25 EU languages. Turbo covers 99 languages | default: measured on the M4 Pro (see the 8 GB row); fallback: research (Whisper small measured: 875 MB, 399 ms) |
| Apple Silicon, 24 GB+ | Parakeet TDT 0.6B v3 (FluidAudio) + custom vocabulary + diarizer | WhisperKit large-v3-turbo | There is RAM to keep ASR, the diarizer and a local LLM cleanup model loaded together | default: measured (this Mac's class); fallback and diarizer: research |
| iPhone, A15 (4 to 6 GB) | Parakeet TDT 0.6B v3 CoreML (FluidAudio needs iOS 17+), run in the host app | WhisperKit base.en / tiny | A keyboard extension has a small memory limit (about 60 MB, not verified), so ASR has to run in the app, not in the keyboard. Not verified on 4 GB phones | research |
| iPhone, A16 / A17 Pro (6 to 8 GB) | Parakeet TDT 0.6B v3 (FluidAudio) | WhisperKit small | | research |
| iPhone, A18 / A19 (8 GB+) | Parakeet TDT 0.6B v3 (FluidAudio) + custom vocabulary | WhisperKit large-v3-turbo (626 MB) | | research |
| Linux CPU only, x86 / ARM | Parakeet TDT 0.6B v3 int8, sherpa-onnx | Parakeet TDT-CTC 110M int8 (sherpa-onnx, 71 ms, 0.011 RTF on CPU) for low-end ARM such as a Raspberry Pi. Moonshine tiny only behind VAD | Same model family as the Mac, one ONNX runtime, no GPU needed | default and fallbacks: measured on the M4 Pro CPU, not on x86 or ARM Linux (default: 3.6 %, 177 ms, 1.8 GB peak RSS) |
| Linux NVIDIA CUDA | Parakeet TDT 0.6B v3 (sherpa-onnx CUDA provider or NeMo) | Whisper large-v3-turbo, whisper.cpp CUDA (99 languages) | Parakeet runs at thousands of times real time on a GPU, which is enough headroom for diarization next to it | research |
| Linux AMD / Intel Vulkan | Whisper large-v3-turbo q5_0, whisper.cpp Vulkan | Parakeet TDT 0.6B v3 int8 on CPU (sherpa-onnx) | whisper.cpp is the only runtime here with mature Vulkan support (and HIP for AMD) | default: research; fallback: measured on the M4 Pro CPU |

### Languages on the Mac

The 🤫 menu's Languages setting picks the model (`speechRoute` in `Sources/ShepetalCore/ModelTier.swift`, tested in
`LanguageTests`):

| Selected languages | Apple Silicon | Without Apple Silicon |
|---|---|---|
| none (automatic) | Parakeet TDT 0.6B v3, which detects the language itself | Whisper base.en |
| only Parakeet v3's 25 (bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk, from the model card) | Parakeet TDT 0.6B v3 | base.en for English only, else large-v3-turbo |
| one other language | Whisper large-v3-turbo q5_0, told that language | the same |
| several, at least one outside Parakeet's | Whisper large-v3-turbo q5_0, told the likeliest chosen language (`pickLanguage`) | the same |

- When the selection needs Whisper and its file is missing, the app does not fall back to Parakeet (it would write the wrong language). The 🤫 menu names the languages that are not installed. The file is `~/Library/Application Support/Shepetal/models/ggml-large-v3-turbo-q5_0.bin` (or `SHEPETAL_WHISPER_MODEL`). whisper.cpp runs in process from the b5454 xcframework (Metal), and the model stays loaded. On an M4 Pro it loads in about 2 s. One chosen language is ready in 0.8 to 1.0 s for a 4 to 11 s clip. With several chosen it takes 1.3 to 2.0 s, because language detection costs one extra encoder pass, as whisper's own `auto` mode does.
- With several languages chosen, whisper's language probabilities (`whisper_lang_auto_detect`) pick the likeliest chosen language, and whisper is told that one, even when a language outside the set ranks first (#31). Told English, large-v3-turbo still writes a Japanese clip in Japanese: the told language decides between close languages (Japanese and Chinese, Spanish and Portuguese), not what was said.
- Parakeet takes no language. When languages are chosen and Apple's text recognizer reads the text as another language (0.9 or more, 3 words or more), a hint shows next to 🤫. The recognizer cannot tell Estonian (it reads it as Finnish, 0.98), Maltese (Norwegian, 0.94), Slovenian (Croatian, 0.88), Latvian or Lithuanian, so with one of those chosen there is no hint (`languagesTextCannotTell`).
- The personal dictionary reaches whisper.cpp as its initial prompt ("Glossary: …", starred entries last because whisper.cpp
  keeps the end of a long prompt). With a bare lowercase word list as the prompt, base.en dropped casing and
  punctuation on one e2e clip; the sentence form fixed it. Parakeet gets the dictionary through the keyword model's rescoring once the user downloads it from the 🤫 menu, in English dictations only (F39, see the Parakeet notes above).

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
./bench/run.sh parakeet-v3 fluid-parakeet-v3 fluid-parakeet-v3-itn fluid-parakeet-v3-int8-v2  # Parakeet v3 rows
./bench/run.sh fluid-parakeet-v3-boost           # dictionary boosting row; its models stay under bench/.cache/home
./bench/run.sh wcpp-large-v3-turbo-q5_0          # not measured yet
```

The `fluid-*` engines build `bench/fluid` (a small SwiftPM CLI on FluidAudio 0.17.7) into `bench/.cache/fluid-build`.
It downloads the model with FluidAudio's own `AsrModels.download` into FluidAudio's default cache,
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`, which is where the Mac app loads it from.
Run `bench/.cache/fluid-build/release/fluid-bench` with no arguments to only download and load it.

`run.sh` creates `bench/.venv` (uv, sherpa-onnx, jiwer), builds `whisper-cli` in `bench/.cache/whisper.cpp`,
downloads models to `bench/.cache`, regenerates fixtures if they are missing, and appends one JSON line per
engine to `bench/results/summary.jsonl`. Weights and the venv are gitignored.

Tests (norm, WER, timing, RSS units, and this page's measured table against `bench/results`; no models needed):

```bash
uv run --no-project --python 3.12 --with jiwer python bench/test_bench.py -v
```

## Sources

- https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 , https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- https://github.com/FluidInference/FluidAudio , https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md , https://docs.fluidinference.com/asr/custom-vocabulary
- https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1 , https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b , https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- https://github.com/argmaxinc/WhisperKit , https://github.com/ggml-org/whisper.cpp
- https://k2-fsa.github.io/sherpa/onnx/hotwords/index.html (hotwords work only with transducer models and modified_beam_search)
- https://huggingface.co/moonshine-ai/moonshine-streaming-tiny , https://huggingface.co/nvidia/canary-1b-flash , https://huggingface.co/nvidia/canary-qwen-2.5b
- https://huggingface.co/kyutai/stt-1b-en_fr , https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602
- https://huggingface.co/pyannote/speaker-diarization-community-1

## Cleanup

Goal rule 5: rewrite-type cleanup runs on a local model. The pipeline is `SmartCleanup.apply` in
`Sources/ShepetalCore/CleanupModel.swift`:

1. **Rules, always** (`Cleanup.apply`): fillers (um, uh, erm, hmm, plus the commas around a mid-sentence one),
   stutters on words that never repeat ("the the"), spacing. First-letter casing to the cursor is
   `InsertionRules`. Snippets are not built yet.
2. **Local model, on cue**: self-corrections and backtracking (cue words such as "actually", "I mean", "no wait", "sorry",
   "scratch that", "make that", "or rather", "correction", ", no"; "I mean it" is emphasis, not a cue), spoken lists (such as "first", "second",
   "number one", "step one", "bullet point", "one, ... two,"), "new line" / "new paragraph", and text with no
   sentence punctuation at all. The model is `LlamaCleanup` (`Sources/ShepetalCleanup/Llama.swift`): llama.cpp
   b11450 (the official `llama-b11450-xcframework.zip`, Metal), greedy decoding, the instructions and 13
   examples decoded once at load, with that state restored for each dictation.
3. **Guard** (`SmartCleanup.accepts`): the model's text is used only when it is the user's own words in
   the user's order, with nothing added: only list numbers at the start of a line may be new, and only
   punctuation, case and line breaks may change, and list numbers must count 1, 2, 3. Words may be left out
   only in two cases. List and line-break markers ("First,", "Number two,", "And finally,", "Bullet point,",
   ". New line.") may go where they start an item; "hire one designer" or "a new line of credit" keep their
   words (in text with no sentence punctuation every marker counts). And a self-correction may go: the whole
   cue ("I mean", "scratch that") together with the words it takes back, which must be one run ending right
   before the cue, from the same sentence (at most 8 words) or from the sentence before when the cue opens a
   sentence (at most 20), no longer than what replaces it plus one. When the replacement starts with a word
   that is also in that run ("the London office, or rather the Berlin office"), the run starts at that word.
   Otherwise the rules' text is inserted. Small models answer questions (Qwen3.5 0.8B turned "What is the capital of Australia?"
   into "The capital of Australia is Sydney.", "Sorry, what is seven times eight?" into "Seven times eight is
   56.", and Qwen3.5 2B turned "Sorry, what is twenty plus twenty two?" into "24") and follow instructions
   (Qwen3.5 2B turned "...reply with the word banana." into "banana"). They also get corrections backwards:
   Qwen3.5 0.8B turned "Send it to John, I mean Jane" into "Send it to John" and swapped "gate twelve.
   Correction, gate fourteen." Since the PR #44 reviews, these are rejected: the order-aware check rejects
   every such output in the committed results (sc01, sc02, sc06, sc11, sc13 for the 0.8B, sc11 for the 2B)
   and keeps every exact match (`SmartCleanupTests.testCorrectionsThatKeepTheWrongHalfAreRejected`), and
   near-copies one word away are rejected too (`testCorrectionsThatKeepTheTakenBackWordsAreRejected`,
   `testListWordsInsideItemsAreKept`, `testListNumbersMustCountUp`). Cue words used without correcting
   ("Sorry, I also need the slides") can still let a rewrite drop the sentence before them (#43). The
   ceiling: a correction said without a cue word stays as heard, and a correction that moves words (sc16,
   "put the notes in the folder, no wait, send them to me") gets the rules' text.
   Dictations over 150 words skip the model (`SmartCleanup.maxModelWords`), and a rewrite that runs past
   1 s throws (`LlamaCleanup.deadline`), so the rules' text is used instead of holding up the paste.
   `LlamaCleanup` serializes calls with a lock, because dictation and History's re-transcribe share it.
4. **Fallback**: no model file, a load error, a model error or the deadline means the rules' text. Home's
   Cleanup line says "On" or "Rules only (...)". Neither it nor the 🤫 menu names a model or file, and the
   details go to stderr.

### Measured on this Mac

63 fixtures in `bench/cleanup/fixtures/dictation.jsonl`, written for shepetal: 16 self-corrections, 3
correction-looking sentences that are not corrections, 8 lists, 3 list-looking sentences, 7 filler, 7 number,
8 technical-term, 6 passthrough (questions and requests that must be typed, not answered), 3 unpunctuated
and 2 spoken line-break transcripts. Each has the transcript as the speech model writes it and the expected
text. Run with `bench/cleanup/run.sh` on the M4 Pro (24 GB, macOS 15.7), Q4_K_M quantization, through the
app's own `LlamaCleanup` code.

| Model (Q4_K_M) | File | Exact, model on every fixture | CER, model on every fixture | Exact, app path | CER, app path | Mean ms per model call | 10 s transcript, median / max ms | Load ms | Peak RSS | Peak footprint | License |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **Qwen3.5 2B** | 1,281 MB | 81 % | 5.4 % | **89 %** | **3.2 %** | 155 | 297 / 313 | 2,188 | 1,545 MB | 356 MB | Apache-2.0 |
| Qwen3.5 0.8B | 533 MB | 59 % | 18.4 % | 65 % | 15.1 % | 99 | 181 / 192 | 1,124 | 801 MB | 292 MB | Apache-2.0 |
| Gemma 3 1B it | 806 MB | 54 % | 18.0 % | 60 % | 13.4 % | 122 | 230 / 242 | 1,411 | 987 MB | 230 MB | Gemma terms |
| Rules only | - | - | - | 43 % | 28.3 % | - | - | 0 | 9 MB | 4 MB | |

How to read it:

- **Exact** is the whole output string equal to the expected one, line breaks included. **CER** is characters
  changed per character of the expected text. "Model on every fixture" sends every fixture to the model with
  no cue gate and no guard; "app path" is what the user gets (rules, gate, model, guard).
- The app-path columns were rerun after the order-aware guard (PR #44 reviews, results in
  `bench/cleanup/results/`): exact match is unchanged (Qwen3.5 2B 89 %, 0.8B 65 %, Gemma 3 1B 60 %); CER rose
  (2.8 to 3.2 %, 13.5 to 15.1 %, 11.9 to 13.4 %) because rejected wrong rewrites now give the rules' text,
  which keeps the cue words. The timing and memory columns are from the first run.
- **10 s transcript** is the model's time on the four fixtures of 24 or more words (about 10 s of speech),
  five runs each: 20 calls, median and max. It is time added on top of speech-to-text. Peak RSS includes the
  memory-mapped model file; peak footprint is `ri_lifetime_max_phys_footprint`, closer to what Activity
  Monitor shows.
- By category, Qwen3.5 2B got 13 of 16 self-corrections, 8 of 8 lists, 3 of 3 unpunctuated transcripts and
  1 of 2 line-break transcripts exactly right. The rules alone get none of those. It missed "today,
  actually, tomorrow?" (it dropped only the cue) and the two 25-word corrections that need a rephrase
  ("send them" must become "send the meeting notes"). Qwen3.5 0.8B got 5 of 16 self-corrections and 7 of 8
  lists; Gemma 3 1B got 7 of 16 and 2 of 8.
- Latency moved between runs on this shared Mac (other agents and Ollama's `llama-server` were using it):
  the same Qwen3.5 0.8B build gave a mean of 99 ms in one run and 148 ms in another, and in one earlier run a
  single 11-word call on Qwen3.5 2B took 702 ms. The final run above had no call over 317 ms.
- The prompt was tuned in three rounds against these fixtures (adding the tags, then more correction
  examples), so the fixture scores are optimistic. The examples in the prompt are different sentences. The
  four cleanup clips in `scripts/e2e-mac.sh` were written after the tuning. On the first list clip ("For the
  trip, we need three things first, the tickets, ...") Qwen3.5 2B dropped the lead-in "we need three things",
  with "number one" instead of "first" too. The guard now rejects that, so the user gets the rules' text, and
  the clip became "We need three things for the trip. First, ...", which it keeps whole.
- The Gemma 3 1B row was rerun after the guard was tightened: on ls07 it dropped the lead-in "Please pick up
  the following", which now falls back to the rules. The two Qwen3.5 rows were rerun too and gave the same
  text on every fixture, so their result files stay as they were.

Earlier prompt versions, not rerun with the final prompt because the shared disk filled up (#29) and the
weights were deleted: LFM2.5 1.2B Instruct (731 MB) scored 35 % exact on every fixture (it answered like a
chat assistant, and its slowest call took 854 ms); Gemma 3 270M it (253 MB) scored 2 %. Their result files are in
`bench/cleanup/results/earlier-prompts/`.

Not measured: Llama 3.2 1B Instruct, LFM2.5 350M, Qwen3 1.7B and Gemma 4 E2B (3.1 GB). There was no disk
space to download them (#29).

### End to end

`scripts/e2e-mac.sh` speaks four cleanup clips with `say` (c01 to c04) on top of the six plain ones and runs
the real app pipeline under `sandbox-exec` with the network denied. With Parakeet v3 and Qwen3.5 2B, the
taken-back words were gone in all four, and text was ready 196 to 421 ms after the end of the audio. The 421
ms is c04, a 10.0 s utterance with a "no wait" correction (424, 452 and 470 ms in earlier runs), so
speech-to-text plus cleanup meets the 700 ms bar on this Mac with about 280 ms to spare. The six plain clips
skip the model and were ready in 61 to 91 ms (52 to 76 ms in an earlier run, and one run had a 263 ms outlier). On main at e44d177 (2026-10-21, #221) the same sandboxed run gave 222 to 544 ms for c01 to c04 and 127 to 219 ms for the plain clips.

### Defaults by Mac tier (`cleanupModel(appleSilicon:ramGB:)`)

| Mac | Default | Why | Status |
|---|---|---|---|
| Apple Silicon, 8 GB | Qwen3.5 0.8B Q4_K_M | Half the resident memory of the 2B (801 vs 1,545 MB) next to Parakeet and the user's apps. It still fixes lists and some corrections; the guard rejects its corrections that keep the wrong half | measured on the M4 Pro 24 GB only, not on an 8 GB Mac or a base M1/M2 |
| Apple Silicon, 16 GB+ | **Qwen3.5 2B Q4_K_M** | Best accuracy here (89 % exact, 3.2 % CER) and 297 ms median, 313 ms max for a 10 s transcript | measured (this Mac's class); 16 GB not measured |
| Intel Mac | rules only | No Apple GPU; llama.cpp would run on the CPU and was not measured | research |

The model runs only on transcripts with a cue, even though Qwen3.5 2B would also meet the 700 ms bar on every
transcript here (no call over 317 ms in the final run). The gate is there for accuracy: on text that
needed no rewrite, the model sometimes changed words or answered, and the gate plus the guard took the score
from 81 % to 89 %. It also keeps plain sentences at speech-to-text speed. The
ceiling: a correction said without a cue word ("Tuesday, Wednesday at three") stays as heard. A slower Mac
(a base M1 has about a quarter of the M4 Pro's memory bandwidth) is likely to need the gate for latency too.
That is not measured.

The model file is downloaded only from the 🤫 menu ("Download cleanup model"), checked against its SHA-256
pinned in `CleanupModelFile`, into `<data>/models`. `SHEPETAL_CLEANUP_MODEL` points the app at another GGUF.
No network call happens during cleanup: the e2e run above is sandboxed with the network denied, and `scripts/e2e-mac.sh` fails when llama.framework links a socket or DNS call (`nm -u`).

Reproduce:

```bash
CLEANUP_MODELS=/path/to/weights bench/cleanup/run.sh     # rules baseline plus every model in the catalog
bench/cleanup/run.sh Qwen3.5-2B-Q4_K_M.gguf              # one model (fetched into bench/.cache/cleanup if missing)
python3 bench/cleanup/score.py                           # the table above from bench/cleanup/results
python3 bench/cleanup/score.py --self-test
```

### Text around the cursor (F24)

Off by default. When Settings' "Use the text around the cursor to clean up dictation" is on, `Pipeline` reads the focused field once, before cleanup (after the rule 8 check), and `SmartCleanup.apply` passes a `CleanupContext` to the model: the last 500 characters before the cursor, the first 500 after it and the selection (up to 500 characters), each cut at a word boundary. `LlamaCleanup` keeps a second cached prompt for it: the same instructions and examples, plus a paragraph and four examples with a `<field>` block in front of the dictation, marked as reference only. The prompt without context is unchanged; on the 63 fixtures above, both Qwen3.5 models gave the same model text as before. The rules still decide whether the model runs, so punctuated text with no correction or list cue never reaches it, field or not. The word guard is unchanged, except that list numbering may go on from a list on the line above the cursor, and "Number three, ..." under such a list counts as a cue. So the field can change case, punctuation and list numbers, never add a word. The field's text is never logged or written to History. It is tokenized as plain text, so chat-template markers in it stay text (`LlamaCleanupTests.testTheFieldCannotInjectControlTokens`).

There are 8 fixtures in `bench/cleanup/fixtures/context.jsonl`: names and terms spelled in the field, two lists that go on, a question in the field that must not be answered, and two dictations under a full 500/500-character field. `python3 bench/cleanup/score.py --context` scores the app path with the context off and on, and prints:

| Model | Exact, off | Exact, on | CER, off | CER, on | Model text used, on | Mean / max ms per model call, off | on |
|---|---|---|---|---|---|---|---|
| Qwen3.5-0.8B-Q4_K_M | 50% | 62% | 28.9% | 18.6% | 7 | 75 / 148 | 113 / 242 |
| Qwen3.5-2B-Q4_K_M | 62% | 88% | 23.9% | 4.6% | 8 | 117 / 246 | 187 / 405 |
| rules | 0% | 0% | 37.2% | 37.2% | 0 | - | - |

- Qwen3.5 2B: the context fixes a term's case and the two lists that go on. It breaks one fixture, a correction under a full field ("Send it to John, I mean Jane, ..."), which it then keeps as said. Qwen3.5 0.8B also breaks one correction under a full field.
- The scores are optimistic. The prompt was tuned against these fixtures: with the field after the dictation, both models wrote the field back, and with the field in front but no examples, they did no cleanup. Five of the eight fixtures are lowercase text with no punctuation, which Parakeet v3 seldom produces.
- End to end, `scripts/e2e-mac.sh` clip c05 is c04 dictated into a field with 596 characters on each side of the cursor, with the setting on. In seven runs on the M4 Pro (load average 4 to 20 from other work), c05 was ready 726 to 800 ms after the end of the audio, against 548 to 577 ms for c04 in the same runs. **A 10 s dictation under a full field misses the 700 ms bar on this Mac.** The correction was made in every run. With the setting off (the default), the bar holds as above.
- The second prompt is decoded at load: Qwen3.5 2B loaded in 1.8 to 3.6 s over three runs.

