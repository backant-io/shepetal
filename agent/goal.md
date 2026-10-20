# GOAL: shepetal covers 100% of Wispr Flow's features on Mac, iPhone and Linux, fully local

You are building shepetal for Pavel Hegler (BackAnt): an open-source (MIT) replacement for Wispr Flow that runs every model on the user's device. Repo: https://github.com/backant-io/shepetal (default branch main).

This is a continuous effort. You work in iterations, and the goal is reached ONLY when `scripts/parity.py` reports 100% coverage AND Pavel has confirmed every hand test. Until then you never stop, never report "finished", and never call the work done.

## The finish line (computed by code, not judged)

`docs/parity.md` is the ledger. It has one row per feature ID (F01...) from `docs/re/feature-inventory.md`, with one column per shepetal platform: Mac, Linux, iPhone.
- **Platform mapping:**
  - Mac covers Wispr's Mac features.
  - Linux covers Wispr's desktop features (Mac and Windows).
  - iPhone covers Wispr's iOS features, plus every desktop feature iOS allows.
- **Cell values:**
  - `done`: needs evidence, meaning the test name(s) plus the PR that landed it on main.
  - `hand-test`: everything that can be automated is done, and the cell waits on a step in docs/manual-test.md.
  - `confirmed`: only Pavel sets this, after he runs the hand test. You never write it.
  - `impossible`: the platform forbids it. Cite the Apple, Linux or kernel doc, and build the closest substitute (example: iPhone cannot capture other apps' call audio, so it records in-person meetings from the mic).
  - `n/a`: only for features that exist solely to serve Wispr's servers or business: billing, subscriptions, referrals, telemetry/analytics, remote feature flags, A/B tests, and account and team administration. Each row gives its reason.
  - `todo`: not built yet.
- **Cloud-backed user features still count.** Wispr features that give the user value through its cloud (cross-device sync, share links, MCP export, team dictionaries, server-side formatting, cloud ASR) are NOT `n/a`. Each needs a local-first equivalent: sync through a folder the user picks (iCloud Drive, Syncthing), sharing by exported file, a local MCP server, local models.
- **`scripts/parity.py` computes the result.** Use plain Python stdlib, with an assert-based self-check. It fails if any inventory ID is missing from the ledger, if a `done` cell has no evidence, or if an `n/a` falls outside the allowed categories. It prints two numbers: **automated coverage** (done + hand-test + confirmed + impossible + n/a, over all cells) and **confirmed coverage** (the same, with hand-test cells counting only once Pavel has confirmed them). The goal is reached when both are 100%.
- **The inventory must be complete before 100% means anything.** Cross-check it against the Wispr bundle (pre-extracted asar at /Users/sorcecoder/shepetal-re/asar): every user-facing settings key in config.json (201), every HelperAPI message (102 requests / 28 responses), every feature flag (about 230), every analytics event name (1,065; each user action implies a feature), every renderer window (9) and every shortcut action. `scripts/parity.py --completeness <map>` reads a mapping file (identifier → F-ID or `internal` with a reason) and fails on any identifier left unmapped. Any feature found this way becomes a new F-ID row. The map lists about 1,600 Wispr identifiers, so it stays OUT of the repo: it lives at /Users/sorcecoder/shepetal-re/identifier-map.tsv, next to the extracted bundle, because committing it would copy Wispr's strings. The check runs on this Mac.

## Each iteration

1. Run `python3 scripts/parity.py` and `gh pr list --state all`, and read docs/progress.md.
2. Pick the next batch: the earliest unfinished milestone first, then P0 before P1 before P2. Items in one batch must own disjoint files. When a platform's app foundation is missing, the foundation is a single item and that platform's other work waits for it.
3. Build each item on its own branch, in a worktree under /Users/sorcecoder/github/backant/shepetal-wt/, with tests that fail when the behavior breaks. Prove that by breaking the code on purpose and seeing a test fail.
4. Before merging, an independent reviewer checks each item. The reviewer does a clean-clone build plus tests, the deliberate-break check, a behavior check against docs/re/ and this goal, and a check that no Wispr code or strings were copied.
5. Merge to main through a PR once it is green. Update docs/parity.md, docs/progress.md (done / verified / left), and docs/manual-test.md.
6. Start the next iteration.

## Where you run

On Pavel's Mac: Apple M4 Pro, 24 GB, macOS 15.7, Xcode 26.3 with the iOS 26.3 simulator, Swift 6.2, Docker, and xcodegen. You use Pavel's claude.ai login; never use or ask for an Anthropic API key.

- No sudo, no brew or other system-wide installs, no System Settings or TCC changes, no login items.
- Project-local SwiftPM, npm, Python venvs and Docker images are fine.
- Don't touch other checkouts under ~/github, or /Users/sorcecoder/shepetal-agent (except reading its re/ files).
- The network is shared, so model downloads can be slow. Cache them under each component's gitignored .cache, start long downloads in the background early, and never commit weights.

## State at the start (2026-10-20 evening)

- **The Mac app does NOT exist.** The Managed Agent meant to build it died at 17:09 with an expired token. It left only a local, uncommitted placeholder (main.swift printing 1) on an unpushed shepetal-v1 branch. Build the Mac app from scratch at the repo root. Ignore shepetal-v1.
- **Open PRs from the first sprint:**
  - #1 Mac meeting detection (meeting/; tests pass on macOS and in the swift:6.2 Linux image)
  - #2 Linux scaffold (linux/, Rust)
  - #3 iPhone app and keyboard (ios/)
  - #4 speech-to-text benchmarks (bench/, docs/models.md; Parakeet v3 not yet measured)
  - #5 non-LLM summarizer (summarize/, docs/summarization.md; its venv borrows torch from another repo, so replace that)
  - #6 reverse-engineering docs (docs/re/) plus this goal
- If a cloud agent publishes more Wispr Flow findings on GitHub, read them and don't redo that work.

## Reverse engineering rules

- Wispr Flow (/Applications/Wispr Flow.app) is read-only: never modify, launch, or quit it.
- Use REA only from the official repo https://github.com/morluto/rea (344k+ stars), as `npx -y rea-agents@latest <command>`. Never run `rea-agents setup`.
- Never download github.com/reverse-engineer-anything/REA-Github or any other copy of REA. That repo is a malware lure.
- Learn behavior only. Never copy Wispr Flow code, prompts, strings, assets or model files. Cite evidence as path + symbol.
- In ~/Library/Application Support/Wispr Flow, read schemas only, never row contents.

## Product rules (Pavel's decisions; don't relitigate them)

1. **fn starts recording, on every platform that has fn.**
   - Hold fn to talk; double-tap it for hands-free.
   - On Linux, fn is evdev KEY_FN (464). Many laptops handle fn in firmware and never report it. If no keyboard reports it, say so plainly and ask the user to pick a key. Never fall back to another key silently.
   - iPhone uses the keyboard's mic button.
   - **Mac: the install sets "Press 🌐 key to" to Do Nothing**, because otherwise fn switches the input source and dictation never starts. The installer's postinstall (run as the logged-in user) and every app launch read `com.apple.HIToolbox AppleFnUsageType`; if it is not 0 they store the old value once, write 0, restart TextInputMenuAgent and TextInputSwitcher (`killall`, `killall -9`) so it applies without a logout, read it back, and say so once next to 🤫. The menu can restore the old value, and uninstalling restores it. No other system setting is touched.
2. **Too-short presses are ignored, with a text.** If fn is released before the hold threshold and no second tap follows, nothing is transcribed and nothing is inserted. A short hint shows next to the 🤫 indicator for about 2 s, in our own wording (for example "Hold fn to talk · double-tap for hands-free"). The audio is still kept (rule 4) and marked "too short" in history.
3. **The 🤫 indicator is tiny, sits in the bottom-left corner, and is always there while shepetal runs.** It is the shushing "psst" emoji, about 18 pt, inset about 8 pt from the bottom-left corner of the main display. It shows at all times while shepetal runs, idle included. It stays on top across all Spaces and over full-screen apps, and it is click-through, so it never takes focus or clicks. It is shepetal's Flow Bar: recording, hands-free, processing, error and hint states all show at or next to it, and it stays tiny.
   - **Mac:** a non-activating, borderless NSPanel.
   - **The app icon is 🤫 too:** AppIcon.icns is rendered from the shushing-face emoji at every size (16 to 1024 px), so Finder, Launchpad, Spotlight and the Privacy & Security lists show 🤫.
   - **Linux:** an override-redirect, always-on-top, sticky window on X11; wlr-layer-shell on KDE, Sway and Hyprland; a small bundled GNOME Shell extension on GNOME Wayland, because GNOME lets no app place overlays.
   - **iPhone:** no system-wide overlay is possible, so show 🤫 in the keyboard's corner and in the Live Activity / Dynamic Island while a session is active.
4. **The raw audio of every recording is kept.**
   - **What is kept:** the exact 16 kHz mono samples the model received, saved as WAV or FLAC next to the history entry. Cancelled and too-short recordings are kept too, marked as such. There is no "never store" option; it is the user's own audio on their own device.
   - **Where:** an owner-only dir (0700 dir, 0600 files; iOS app container with FileProtectionType.complete, never the App Group). Never in /tmp, never uploaded.
   - **What it's for:** history replays it and can re-transcribe it with another model.
   - **Retention:** keep (the default) or delete after 24 h.
5. **Everything runs on the device.** Speech-to-text uses the best local model for the machine, from the tier table in docs/models.md, chosen at first run by chip/GPU and RAM; measure any tier that is missing. Rewrite-type features (cleanup, command mode, styles) use a local model that you choose and document. No network call happens during transcription, cleanup or summarization.
6. **Meeting summaries come from a separate local model that is NOT an LLM.**
   - Use the docs/summarization.md recommendation: today that is extractive TextRank plus rules.
   - Keep a GitHub issue that tracks Next-Concept Modeling (https://github.com/HazyResearch/ncm) for when it can write long-form summaries and run on Apple Silicon or CPU.
   - Validate against real meeting corpora (AMI, QMSum), not only self-written fixtures.
7. **Meetings are detected automatically on Mac and Linux.**
   - Detection follows docs/re/meetings.md: mic holders, window or tab titles, calendar, and the start/end thresholds as tunable config.
   - Capture mic and system audio as separate channels: a Core Audio process tap on Mac, the PipeWire monitor source on Linux.
   - Transcribe live with a streaming model, diarize locally, and use calendar names when available.
   - On iPhone, record in-person meetings from the mic.
8. **Text only goes into the window that stayed in focus; otherwise it goes to the clipboard.** When a dictation starts, shepetal remembers the focused window. It pastes only if that same window is still in focus when the text is ready, and it never moves focus back: no refocusing or reactivating the original app. If focus moved, or the paste does not land, the text is left on the clipboard as plain text (the user's old clipboard is not restored in that case), and the hint next to 🤫 says to press ⌘V. This applies on every platform that can tell which window or field is focused. On iPhone, a result for a different field goes to the clipboard instead of being discarded.
9. **Donate.** Every app shows Donate links: https://buymeacoffee.com/sorcecoder and https://github.com/sponsors/backant-io.

## Milestones (each ends in merged PRs)

- **M0:** Write scripts/parity.py, docs/parity.md and the local identifier map. Run the completeness check and add any missing features to the inventory. Rebase and land PRs #1–#6, running PR #4's Parakeet v3 benchmark. Write docs/architecture.md, covering the repo layout, the shared core and the per-platform shells.
- **M1:** Mac app foundation, working end to end:
  - a menu-bar app with the 🤫 indicator;
  - fn hold / double-tap / short-press hint;
  - recording with raw audio kept;
  - local STT (FluidAudio Parakeet v3, with the docs/models.md fallback);
  - insertion by clipboard plus Cmd+V with a paste-success check and clipboard restore (per docs/re/insertion-context.md), or Accessibility where that proves better;
  - history and the permission onboarding;
  - an installer: `Shepetal-<version>.pkg` (pkgbuild + productbuild, script in the repo) installs Shepetal.app to /Applications, and its postinstall, as the logged-in user, sets the 🌐 key to Do Nothing, turns on launch at login and opens the app, so the user only grants the three permissions. The app is signed with the maintainer's Apple Development identity when there is one; an uninstall script removes the app and the login item, restores the 🌐 key setting, and keeps the user's recordings and history.
- **M2:** Mac P0 parity.
- **M3:** Mac meetings plus the summarizer.
- **M4:** Linux P0 parity plus meetings.
- **M5:** iPhone P0 parity plus in-person meetings.
- **M6 and on:** P1, then P2, on every platform, until scripts/parity.py reports 100%.

## Verification

- **Builds and tests.**
  - Mac: `swift build` and `swift test`, plus an app bundle that launches.
  - iPhone: `xcodebuild ... test` on the iOS simulator.
  - Linux: build and tests in Docker on ubuntu:24.04.
  - Run from a clean clone, with the exact commands in each README and the real output in the PR.
- **Headless end-to-end on Mac.** The app has a debug entry point that runs the real pipeline on an audio file (`say`-generated): STT → cleanup → history + audio file → insertion into a test text field the app owns. The test checks the inserted text and the saved audio.
- **Visible UI.** Launch the built Mac app and take a screenshot (screencapture) to show the 🤫 indicator in the bottom-left corner and the short-press hint. If screen capture isn't permitted, the cell becomes `hand-test`.
- **Accuracy and speed.** On the dictation fixtures, the default model on this Mac reaches WER ≤ 8%, with text ready ≤ 700 ms after release for a 10 s utterance. The numbers go in docs/models.md.
- **Meeting detection fixtures** (Core Audio process lists, pw-dump JSON): the detector starts and ends within the docs/re/meetings.md thresholds, ignores shepetal's own dictation, and handles flapping and two meeting apps at once.
- **Summaries:** on meeting fixtures and real corpora, at least 80% of action items are recovered with the right owner.
- **Raw audio:** a test per platform checks that every recording's history entry points to an owner-only file holding the samples the model got, cancelled and too-short ones included, and that the 24 h option deletes on time.
- **Privacy:** a test shows that no network request happens during transcription, cleanup or summarization.
- **What you can't do yourself:** you cannot press physical keys, speak, join calls, or grant permissions. Anything that depends on those is `hand-test`, with exact steps in docs/manual-test.md. It is never called "verified".

## Git rules

- Commit with the configured identity (Pavel Hegler). Use plain messages that say what changed. No Co-Authored-By lines, and no mention of Claude or AI in commits or PRs.
- Work on branches, open PRs against main, and merge them once they're green. Never force-push, delete branches, push to main directly, or change repository settings.
- Write the least code that does the job. Don't add speculative abstractions.
- Fail loud. Anything skipped or failing goes in the PR, in docs/progress.md, and in a GitHub issue. Never mark work done when it isn't.
