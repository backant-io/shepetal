# Progress

## Iteration 1 (2026-10-20), main at 60cc333

`python3 scripts/parity.py` gives these numbers. Only Mac cells moved this iteration.

| | Cells | Coverage |
|---|---|---|
| Automated coverage | 24 of 372: 18 n/a + 6 hand-test | 6.5% |
| Confirmed coverage | 18 of 372: n/a only | 4.8% |

The `--completeness` check maps all 1639 Wispr identifiers and passes.

### Done (merged to main)

| PR | What | Ledger effect |
|---|---|---|
| #6 | Wispr Flow behavior notes (`docs/re/`), the 113-row inventory (124 after #7), the goal, `check_re_docs.py` | inventory source |
| #1 | `meeting/`: meeting detector and Core Audio capture for Mac | none yet: the app does not use it (#16) |
| #4 | `bench/`, `docs/models.md`: Parakeet v3 measured, 7.2% WER and 62 ms mean on FluidAudio | model tier table |
| #5 | `summarize/`, `docs/summarization.md`: TextRank plus rules, scored on QMSum/AMI | none yet: action items 4.4% (#8) |
| #3 | `ios/`: iPhone app, keyboard extension, handoff, kept audio, 🤫 in the keyboard corner | none yet: no device steps in `docs/manual-test.md` (#19) |
| #7 | `scripts/parity.py`, `docs/parity.md`, `scripts/extract_identifiers.py`, F114 to F124 | ledger |
| #10 | Mac app foundation: fn gestures, 🤫 panel, Parakeet v3, kept audio, history, paste insertion, permissions | Mac F01, F02, F19, F20, F53, F112 to `hand-test` |

#7 and #10 were based on `re/wispr-flow-full`. They were retargeted to main after #6 merged. #10 conflicted with main only in `.gitignore`, where both sides had appended lines. main was merged into the branch (no rebase), both sides were kept, and the tests were re-run before the merge.

### Verified

These were run on main at 60cc333 on the M4 Pro (macOS 15.7, Xcode 26.3, Swift 6.2), in `/Users/sorcecoder/github/backant/shepetal-wt/ledger`:

| Command | Result |
|---|---|
| `swift build && swift test` | 35 tests, 0 failures |
| `cd meeting && swift build && swift test` | 17 tests passed |
| `git archive HEAD meeting \| docker run -i swift:6.2 ... swift test` | 14 MeetingCore tests passed on Linux |
| `cd ios && xcodegen generate && xcodebuild -scheme Shepetal -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build test` | 44 tests, 0 failures, BUILD and TEST SUCCEEDED |
| `cd summarize && .venv/bin/python -m unittest` (numpy only) | 13 tests OK |
| `uv run --no-project --python 3.12 --with jiwer python bench/test_bench.py` | 8 tests OK |
| `python3 scripts/check_re_docs.py` | 9 docs, 111 quoted prose spans, 124 inventory rows: ok |
| `python3 scripts/parity.py --self-test`, `python3 -I scripts/extract_identifiers.py --self-test` | self-test ok |

`sandbox-exec -p '(version 1)(allow default)(deny network*)' scripts/e2e-mac.sh` passed on 982e547: WER 0.0% over 6 clips and 58 to 78 ms to text. 982e547 has the same tree as main at 60cc333, but this was an incremental build, not a clean clone.

### Left (next iterations, in goal order)

- **M0:** Linux #2 is still open. A separate workflow owns it, so every Linux cell is `todo`.
- **M1 Mac:** the hand tests in `docs/manual-test.md#mac` (#15). Automated tests for the 🤫 panel frame and flags (F05), the `paste_failed` path and the empty-transcript path (#15). The Parakeet e2e numbers in `docs/models.md`.
- **M2 Mac P0 parity.** These Mac P0 cells are still `todo`: F03 Esc cancel, F04 rebindable shortcuts, F05, F06 sounds, F07 mic selection, F08 mic health, F10 max length, F12 languages, F17 Secure Input, F21 paste/copy last, F23 app and URL awareness, F27 focus restore, F32 local-model cleanup, F39 dictionary, F51 empty-transcript guard, F52 history search, retry and playback, F88 screen and system-audio permissions, F89 onboarding, F90 revoked permissions, F91 hub window, F92 launch at login, F99 crash recovery, F109 NBSP and selection rules.
- **M3:** wire `meeting/` and the summarizer into the Mac app (#16, #18). Action items need 80% on real meetings (#8).
- **M5:** move the iPhone device steps into `docs/manual-test.md` (#19) and run on a device (#13, #14). Add the Live Activity, `AudioRecordingIntent` and the keyboard cancel (#13).
- Unmeasured benchmarks (#17). CI (#21). Resolve the fn threshold divergence (#22).

### Blocked

- **Hand tests:** Pavel has to run the `docs/manual-test.md` steps. Until then the 6 Mac `hand-test` cells cannot become `confirmed` (#15).
- **Finish line:** the Mac and Linux cells of the iOS-only rows F108 and F116 cannot reach any allowed value, so 100% is unreachable until Pavel decides (#20).
- **Linux:** waits on #2.

### Open GitHub issues

| # | Title |
|---|---|
| #8 | Summarizer action items recover 4-7% of real AMI action items (goal needs 80%) |
| #9 | Inventory F15 and F31 have no local plan (plan text says skip at P2) |
| #11 | Mac: whisper.cpp fallback is not bundled and is over the 700 ms bar |
| #12 | Track Next-Concept Modeling (NCM) for long-form meeting summaries |
| #13 | iPhone: gaps left after the PR #3 review fixes |
| #14 | iOS: stop notification is unauthenticated; check App Group state before stopping |
| #15 | Mac app (#10): hand tests pending and shell paths without automated tests |
| #16 | Mac meetings (#1): calendar, wake and hardware capture unverified, and not wired into the app |
| #17 | STT benchmarks (#4): cold load, ANE memory, WhisperKit, streaming and other machines not measured |
| #18 | Summarizer (#5): seq2seq, decisions on real data and STT-error effect not measured |
| #19 | iPhone and meeting device steps are not in docs/manual-test.md, so their ledger cells stay todo |
| #20 | Ledger: Mac and Linux cells of iOS-only rows F108 and F116 have no value that can close them |
| #21 | No CI: iteration 1 PRs merged on local runs, and scripts/ci/run-checks.sh is missing |
| #22 | fn hold threshold and double-tap window differ between Mac (500/500 ms) and the Linux branch (300/400 ms) |

### Count notes (from #7)

The extracted bundle disagrees with the counts in the goal:
- Settings keys: 202, where the goal says 201. That is 179 defaults plus 23 keys found only in `config.json`.
- Feature flags: 203, where the goal says about 230.
- Analytics events: 1064, where the goal says 1065.

The HelperAPI messages (102 requests, 28 responses) and the windows (9) match.

## CI (#21)

`scripts/ci/run-checks.sh` runs every suite and stops at the first failure: `swift`, `meeting`, `ios`, `summarize`, `bench`, `scripts`, `linux`, `meeting-linux`. `--fast` skips `ios` and the two Docker suites, and `--only SUITE` runs one suite. `.github/workflows/ci.yml` runs the same suites on every pull request and on every push to main, in a macos-26 job (Xcode 26.3, Swift 6.2) and an ubuntu-24.04 job (Docker: ubuntu:24.04 for `linux/`, swift:6.2 for MeetingCore).

Not run in CI:
- `scripts/e2e-mac.sh` needs the 470 MB Parakeet v3 model. Run it by hand before a change to the Mac pipeline lands.
- The copied-Wispr-string check in `check_re_docs.py` and `parity.py --completeness` need `/Users/sorcecoder/shepetal-re/`, so CI runs `check_re_docs.py --no-bundle`. `run-checks.sh` runs both checks in full when that folder exists.
- `linux/` is not on main yet (#2). Until it is, the `linux` suite prints `linux/: not on this branch`.
