# GOAL: shepetal reaches Wispr Flow feature parity on Mac, iPhone and Linux, fully local

You are building shepetal for Pavel Hegler (BackAnt): an open-source (MIT) replacement for Wispr Flow that runs every model on the user's device. Repo: https://github.com/backant-io/shepetal (default branch main).

The goal is reached when every P0 and P1 feature in docs/re/feature-inventory.md works on each platform where it is possible, using local models only, and each one is verified as described under "Done means" below. Keep working through the milestones until then. Do not stop at a scaffold.

## Who else is working on this

- **The v1 builder** (a Managed Agent on this Mac) is building the macOS dictation app at the repo root (Package.swift, Sources/, Tests/) on branch shepetal-v1, and writing docs/wispr-flow-findings.md. Don't edit its branch. When its PR is open, build on it. When it lands, rebase onto main.
- **The Ubuntu agent** is reverse engineering Wispr Flow in the cloud. Read its findings once they are on GitHub, and don't redo work it has finished.
- **The sprint of 2026-10-20** left these behind. Read them all before you write any code:
  - docs/re/{dictation-input, insertion-context, meetings, text-pipeline, app-architecture, feature-inventory, mobile-and-platforms}.md
  - docs/models.md and bench/
  - docs/summarization.md and summarize/
  - the draft PRs feat/meeting (meeting/), feat/ios (ios/), feat/linux (linux/), feat/bench and feat/summarize
- Run `gh pr list --state all` and `git fetch` at the start of every milestone.

## Where you run

On Pavel's Mac: Apple M4 Pro, 24 GB, macOS 15.7, Xcode 26.3 with the iOS 26.3 simulator, Swift 6.2, Docker, and xcodegen. Work in your own git worktree under /Users/sorcecoder/github/backant/shepetal-wt/.

- No sudo, no brew or other system-wide installs, no System Settings or TCC changes, no login items or launch agents.
- Project-local SwiftPM, npm, Python venvs and Docker images are fine.
- Don't touch other checkouts under ~/github or /Users/sorcecoder/shepetal-agent.

## Reverse engineering rules

- Wispr Flow is installed at /Applications/Wispr Flow.app and is read-only: never modify, launch, or quit it. A pre-extracted app.asar is at /Users/sorcecoder/shepetal-re/asar.
- Use REA only from the official repo https://github.com/morluto/rea (344k+ stars), as `npx -y rea-agents@latest <command>`. Never run `rea-agents setup`.
- Never download github.com/reverse-engineer-anything/REA-Github or any other copy of REA. That repo is a malware lure.
- Learn behavior only. Never copy Wispr Flow code, prompts, strings, assets or model files. Cite evidence as path + symbol.
- When the inventory has a gap, reverse engineer it and add it to docs/re/ before you build it.

## What to build

Ship one product on three platforms. The shared logic is pure code with unit tests: gesture timing, model selection, the meeting detector, text cleanup rules, the dictionary, snippets and summary formatting.

1. **Dictation on all platforms.**
   - Recording starts with fn: hold it to talk, double-tap it for hands-free. This is the same on Linux, where fn is evdev KEY_FN (464). Many laptops handle fn in firmware and never report it. If no keyboard reports it, shepetal says so plainly and asks the user to pick a key, and never falls back to another key silently.
   - Text is inserted at the cursor in any app. On Mac use Accessibility first and fall back to a paste that restores the clipboard. On Linux use wtype, xdotool or ydotool, with a clipboard fallback. On iPhone use a custom keyboard, with recording done in the containing app, because keyboard extensions get no microphone.
   - Every dictation keeps its raw audio: the exact 16 kHz mono samples the model received, saved as WAV or FLAC next to its history entry. It goes in a private data dir that only the user can read (0700 dir, 0600 files; iOS Data Protection on), never in /tmp, and is never uploaded. History can replay it and re-transcribe it with another model. It is the user's own audio on their own device, so it is always stored, cancelled dictations included (marked cancelled in history). No setting turns storage off. The only retention choice is keep (the default) or delete after 24 h.
   - Also ship: personal dictionary, snippets, filler-word and self-correction cleanup, styles per app, history, stats, and multilingual input. Build these in the way docs/re/ describes.
2. **Best local speech-to-text model for the machine.** At first run, detect the chip/GPU and RAM and pick the model using the tier table in docs/models.md. If the table is missing a tier, benchmark that tier and add it. Models download on first run. Never commit model weights. No network calls happen during transcription.
3. **Meeting detection and transcripts.**
   - Mac and Linux detect a meeting on their own: Zoom, Teams, Meet in the browser, Slack huddles, FaceTime, Webex and Discord.
   - Detection uses the processes holding the microphone (Core Audio process objects on Mac, the PipeWire graph on Linux), window or tab titles, and calendar events if the user allows it, with debounced start and stop. Dictation by shepetal itself never counts as a meeting.
   - Capture mic and system audio as separate channels. On Mac that is a Core Audio process tap; on Linux it is the PipeWire monitor source.
   - Transcribe live with a streaming local model, diarize speakers locally, and use attendee names from the calendar when available.
   - On iPhone, offer mic-only recording of in-person meetings and say plainly that other apps' call audio cannot be captured.
   - Ask for consent the way docs/re/meetings.md describes, with a notice that the user can show to participants.
4. **Meeting summaries from a separate local model that is NOT an LLM.**
   - Pavel asked for "the new procedural text gen model family". The first candidate is Next-Concept Modeling, Hazy Research, October 2026 (https://github.com/HazyResearch/ncm).
   - Use whatever docs/summarization.md recommends. If NCM has no usable weights, use the best non-LLM fallback it measured, and open a GitHub issue that tracks moving to NCM.
   - The output has these sections: overview, key points, decisions, and action items with owner and due date.
   - Meetings are stored locally and searchable, with export to Markdown.
5. **Donate.** Every app shows Donate links: https://buymeacoffee.com/sorcecoder and https://github.com/sponsors/backant-io.
6. **Out of scope:** accounts, cloud sync, telemetry, and any server-side processing. Any feature that needs a rewrite model, such as command mode, uses a local model that you choose and document. Never call a cloud API for it.

## Milestones

Each milestone ends in its own PR, and docs/progress.md is updated after each one with what was done, what was verified, and what is left.

- M0: Integrate the sprint PRs: rebase them, get them green and merge them. Then write docs/architecture.md, covering the repo layout, the shared core and the per-platform shells.
- M1: Mac dictation reaches P0 parity, on top of the v1 app.
- M2: Mac meetings: detection, capture, live transcript and diarization.
- M3: Summarizer integrated on Mac.
- M4: Linux reaches P0 parity plus meetings.
- M5: iPhone keyboard and app reach P0 parity, plus in-person meetings.
- M6: P1 features on all platforms, then a parity audit against docs/re/feature-inventory.md that marks every row done, partial (with the reason), or not possible on that platform (with the reason).

## Done means (verify each, and put the evidence in the PR)

- **Build and test.**
  - Mac: `swift build` and `swift test`.
  - iPhone: `xcodebuild ... test` on the iOS simulator.
  - Linux: build and tests pass in Docker on ubuntu:24.04, with the exact commands written in each README.
  - Each command is run from a clean clone, and its output is shown.
- **Accuracy and speed.** Generate synthetic audio with `say` on Mac and espeak-ng or piper in the Linux container. On the dictation fixtures, the default model on this Mac reaches WER ≤ 8%, and text is ready ≤ 700 ms after release for a 10 s utterance. The numbers go in docs/models.md.
- **Meeting detection.** Recorded snapshot fixtures (Core Audio process lists, pw-dump JSON) cover these cases:
  - the detector starts ≤ 10 s after a meeting app takes the mic;
  - it ends ≤ 30 s after the app releases the mic;
  - it ignores shepetal's own dictation;
  - it handles flapping and two meeting apps at once.
  The tests must fail if a threshold or the self-exclusion is broken.
- **Summaries.** On synthetic two-to-four-speaker meeting fixtures with known decisions and action items, the summarizer recovers at least 80% of the action items, with the right owner. The ROUGE scores and latency go in docs/summarization.md.
- **Raw audio.** A test on each platform checks three things. Every dictation's history entry points to an audio file that exists, is owner-only, and holds the same samples the model received. No setting stops the file from being written. "Delete after 24 h" removes the files once 24 h have passed.
- **Privacy.** A test or a documented check shows that no network request happens during transcription or summarization.
- **Hand testing.** docs/manual-test.md has the exact steps Pavel follows on each platform: granting permissions, checking each feature, and checking meeting detection in a real Zoom or Meet call.
- **Clean tree.** No TODOs, placeholder text, dead code or committed weights.

You cannot press keys, speak, join calls, or grant permissions. Keep everything that depends on those as pure logic with tests, plus a manual-test entry. Report it as "needs hand test" and never as "verified".

## Git rules

- Commit with the git identity already configured (Pavel Hegler). Use plain messages that say what changed. No Co-Authored-By lines, and no mention of Claude or AI in commits or PRs.
- Work on branches and open PRs against main with `gh pr create`. Never force-push, delete branches, push to main directly, or change repository settings.
- Write the least code that does the job. Don't add speculative abstractions.
- If something is skipped or fails, say so in the PR and in docs/progress.md, and open a GitHub issue for it. Never mark work as done when it isn't.
