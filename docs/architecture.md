# Architecture

What is on main after iteration 1 (60cc333). On each platform, shepetal is a thin native shell around a core that has no UI or hardware code in it. The core can be tested without a mic, a model or permissions. The behavior rules come from `agent/goal.md` and `docs/re/`.

## Repo layout

| Path | What | Language, build | Tests |
|---|---|---|---|
| `Package.swift`, `Sources/`, `Tests/` | Mac app: `ShepetalCore` (logic), `ShepetalCleanup` (the local cleanup model on llama.cpp) and `Shepetal` (AppKit shell) | Swift 6 / SwiftPM, macOS 14+ | `swift build && swift test`, `scripts/e2e-mac.sh` |
| `meeting/` | Meeting detection and capture: `MeetingCore` (portable), `MeetingMac` (Core Audio, EventKit), CLI `shepetal-meeting` | Swift / SwiftPM, macOS 14.4+; MeetingCore also builds on Linux | `cd meeting && swift test`, plus MeetingCore in `swift:6.2` on Linux |
| `ios/` | iPhone: `ShepetalSessionCore` (framework), `Shepetal` (app), `ShepetalKeyboard` (keyboard extension) | Swift, XcodeGen `project.yml`, iOS 17+ | `xcodegen generate && xcodebuild ... test` on the iOS simulator |
| `summarize/` | Meeting summarizer: extractive TextRank plus rules (not an LLM), and the QMSum/AMI eval | Python, numpy only on the default path | `python -m unittest` |
| `bench/` | STT benchmark harness, plus `bench/fluid`, a FluidAudio CLI, and `bench/cleanup`, the cleanup-model benchmark | Python with uv, SwiftPM | `bench/test_bench.py`, `bench/cleanup/score.py --self-test` |
| `scripts/` | `parity.py` (ledger and coverage), `extract_identifiers.py`, `check_re_docs.py`, `make-app.sh`, `e2e-mac.sh` | Python stdlib, bash | `--self-test` on each Python script |
| `docs/` | `parity.md` (ledger), `progress.md`, `manual-test.md`, `models.md`, `summarization.md`, `re/` (Wispr Flow behavior notes and the feature inventory) | Markdown | `check_re_docs.py`, `parity.py` |
| `agent/` | The goal and the agent runner | | |
| `linux/` | Not on main. Linux is PR #2 (Rust), which a separate workflow is still working on | Rust | `cargo test` in `ubuntu:24.04` |

Model weights, venvs and build output live in each component's gitignored `.cache/`, `.venv/` or `.build/`. The Wispr identifier map and the extracted bundle stay outside the repo, in `/Users/sorcecoder/shepetal-re/`.

## Shared logic, per platform

No code is shared across platforms yet. Each platform implements the same rules in its own core, and the rules themselves are shared through the docs. This table shows where each rule lives.

| Rule (source) | Mac | iPhone | Linux (PR #2, not on main) |
|---|---|---|---|
| Start gesture (goal rules 1 and 2, `docs/re/dictation-input.md`) | `ShepetalCore/FnGesture.swift`: hold over 0.5 s talks, a second tap within 0.5 s gives hands-free, a shorter press is `tooShort` with the hint, another key in the first second cancels | keyboard mic button, `Core/Handoff.swift` state machine. Under 0.3 s is too short | `gesture`: 300 ms hold, 400 ms double tap |
| Raw audio kept (goal rule 4) | `ShepetalCore/AudioStore.swift`: 16 kHz mono Float32 WAV, 0700 dir, 0600 files, keep or delete after 24 h | `Core/DictationSession.swift` `AudioArchive`: app container, `FileProtectionType.complete`, excluded from backup, keep or delete after 24 h | `$XDG_DATA_HOME/shepetal/audio`, 0700/0600 |
| History | `ShepetalCore/History.swift` (SQLite, 0600) | `audio/<id>.json` next to each WAV | not built |
| Dictation flow | `ShepetalCore/Dictation.swift` (mic and transcriber injected) | `Core/DictationSession.swift` (a `Microphone` protocol and a transcribe closure) | daemon in PR #2 |
| Insertion text rules (`docs/re/insertion-context.md` 2.5) | `ShepetalCore/TextRules.swift`: spacing, casing, paste check, filler and stutter cleanup | not needed: `textDocumentProxy` inserts directly | wtype / xdotool / ydotool over stdin |
| Cleanup model (goal rule 5, `docs/models.md` Cleanup) | `ShepetalCore/CleanupModel.swift`: rules, cue gate, word guard, tier choice; `ShepetalCleanup/Llama.swift`: llama.cpp with Metal | not built | not built |
| Model choice (goal rule 5, `docs/models.md`) | `ShepetalCore/ModelTier.swift` | Parakeet v3 through FluidAudio | `model` (whisper.cpp tiers) |
| 🤫 indicator (goal rule 3) | `Shepetal/Indicator.swift` (shell only, untested, #15) | `Core/Indicator.swift` (keyboard corner, tested) | not built |
| Meeting detection (goal rule 7, `docs/re/meetings.md`) | `meeting/Sources/MeetingCore/MeetingDetector.swift`. It builds on Linux too, but no app uses it yet | in-person mic only (not built) | `meeting`: `pw-dump` parser |
| Meeting summary (goal rule 6) | `summarize/summarize.py`. `docs/summarization.md` gives the Swift and Linux port plan, and no app uses it yet | same | same |

**Divergence to resolve.** The fn thresholds differ: Mac uses 0.5 s and 0.5 s, from the debounce in `docs/re/dictation-input.md`, and PR #2 uses 300 ms and 400 ms. One value set should win (#22).

`MeetingCore` and the `ShepetalCore` rules are pure Swift. A shared Swift package for Mac and iPhone is possible, but nothing shares one yet. iPhone reimplements the audio archive and the history in `ios/Core`.

## Per-platform shells

**Mac** (`Sources/Shepetal/`, built into `dist/Shepetal.app` by `scripts/make-app.sh`):
- `App.swift`: menu-bar item (Recent, Recordings retention, Permissions, Donate, Quit) and the hourly retention sweep.
- `Indicator.swift`: borderless, non-activating `NSPanel`, 18 pt, 8 pt from the bottom-left corner, on all Spaces, click-through.
- `FnTap.swift`: listen-only `CGEventTap` for fn (63, flagsChanged), re-enabled when macOS disables it. The Globe key's extra keycode 179 key events are ignored.
- `Audio.swift`: `AVAudioEngine` capture, resampled to 16 kHz mono.
- `Speech.swift`: FluidAudio Parakeet TDT 0.6B v3 from its local cache, with whisper.cpp `whisper-cli` as the fallback.
- `Inserter.swift`: promised pasteboard item, Cmd+V, paste check, clipboard restore, and the text around the cursor read through Accessibility.
- `Permissions.swift`: Microphone, Input Monitoring and Accessibility status, with Grant buttons.
- `Pipeline.swift` and `E2E.swift`: the real pipeline, and `--e2e <wav>` for the headless end-to-end test.

**iPhone** (`ios/`):
- `App/ShepetalApp.swift`: records with `AVAudioEngine` in the audio background mode, transcribes with FluidAudio, and shows history, the retention toggle and the Donate links.
- `Keyboard/KeyboardViewController.swift`: mic, globe and delete keys, with no audio or model. It opens the app with `shepetal://dictate?id=` and inserts the result through `textDocumentProxy`.
- Transport: App Group `UserDefaults` for state and Darwin notifications to signal. Audio never enters the App Group.

**Mac meetings** (`meeting/`): `MeetingMac/Probes.swift` reads mic holders, window titles (only when Screen Recording is already granted), the calendar (only when access is already granted), devices and the wake marker. `MeetingMac/Capture.swift` uses a process tap and a private aggregate device to write `Me.wav` and `Others.wav`. Today it is a CLI only.

**Linux** (PR #2, not on main): a Rust daemon using evdev for fn, `pw-record` or `parecord` for audio, `whisper-cli` for speech-to-text, and wtype, xdotool or ydotool for insertion.

## Network

No component makes a network call during transcription, cleanup or summarization. The Mac e2e test runs under `sandbox-exec` with network denied, and the summarizer's default path imports only numpy. The model download is the one network step: on Mac it runs only when the user clicks it in the menu, and on iPhone at first launch.
