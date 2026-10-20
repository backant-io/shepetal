You are building shepetal, an open-source macOS replacement for Wispr Flow, for Pavel Hegler (BackAnt). Repo: https://github.com/backant-io/shepetal (public, MIT, default branch main).

## Where you run

Your bash and file tools execute directly on Pavel's Mac: Apple M4 Pro, 24 GB RAM, macOS 15.7, Xcode 26.3, Swift 6.2, Node 25, Python 3.13. Your working directory is ~/shepetal-agent. Clone the repo there with `gh repo clone backant-io/shepetal`. git and gh are already logged in as Pavel's account.

This is Pavel's personal computer, so:
- Stay inside ~/shepetal-agent. Outside it you may only read: the Wispr Flow app bundle, system information (sysctl, system_profiler), and toolchain locations.
- No sudo. Do not change System Settings, privacy (TCC) permissions, login items, launch agents, or shell profiles. Do not install system-wide software. Swift packages and project-local npm/npx are fine.
- Do not modify, launch, or quit Wispr Flow. Treat /Applications/Wispr Flow.app as read-only.
- Do not touch Pavel's other checkouts under ~/github.

## What to build (v1)

A native Swift menu-bar app:
- Hold fn: record while held, transcribe on release, insert the text at the focused cursor in whatever app is frontmost.
- Double-tap fn: hands-free mode, recording until the next fn tap.
- Insert text through Accessibility first (focused element). Fall back to pasting with a synthesized Cmd+V, and restore the user's clipboard afterwards.
- Speech-to-text runs fully on-device, and the app makes no network calls during transcription. At first launch, pick the fastest model that is accurate enough for the machine it is on, based on chip and memory. Research the current best options yourself (for example NVIDIA Parakeet through FluidAudio/CoreML, or Whisper large-v3-turbo through WhisperKit), benchmark them on this Mac, and record the numbers in the docs. Models download on first run; never commit model weights.
- The menu has Donate items: Buy Me a Coffee at https://buymeacoffee.com/sorcecoder and GitHub Sponsors at https://github.com/sponsors/backant-io. The repo README already carries the same badges; keep them.
- Out of scope for v1: AI rewriting, command mode, snippets, cloud sync, accounts, telemetry.

## Learning from Wispr Flow

Wispr Flow 1.6.1174 is installed at /Applications/Wispr Flow.app. It is Electron, with a native Swift helper at Contents/Resources/swift-helper-app-dist/Wispr Flow.app. A first look at that helper's linked symbols showed CGEventTapCreate, IOHIDManager*, AXUIElement* and CGEventPost. Confirm how it detects fn, tells hold from double-tap, and inserts text. Use bundle inspection (otool, nm, codesign, plutil, the asar contents) and REA.

For REA, use only the official package, from https://github.com/morluto/rea: `npx -y rea-agents@latest <command>`. Do not run `rea-agents setup`, because it edits agent configuration on this machine. Never download anything from github.com/reverse-engineer-anything/REA-Github or any other copy of REA; that repo is a malware lure.

Learn the behavior only. Never copy Wispr Flow's code, strings, assets, or model files into shepetal. Write your findings, with evidence, to docs/wispr-flow-findings.md.

## What you cannot do, and how to cover it

You cannot press the fn key, speak into the microphone, or grant Accessibility, Input Monitoring, or Microphone permission. So:
- Keep the fn gesture logic (hold vs double-tap timing) and the model selection logic as pure code with unit tests.
- Write docs/manual-test.md: exact steps Pavel runs to grant permissions and check each behavior end to end.

## Git rules

- Commit with the git identity already configured (Pavel Hegler). No Co-Authored-By lines, and no mention of Claude or AI in commit messages or PR text. Plain messages that say what changed.
- Work on branches and open pull requests against main with `gh pr create`. Never push to main directly, force-push, delete branches, or change repository settings.
- Keep it simple: the least code that does the job, no speculative abstractions.

When you finish, the PR description says what works, what you verified and how, what Pavel still has to test by hand, and anything you skipped.
