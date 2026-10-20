# Progress

## Iteration 2 (2026-10-20 evening): six parallel sessions

Six sessions (release, merge-a, merge-b, quality, linux, ios) work from one shared clone. Each one keeps its own subsection here, newest merge first. Pavel's priority for tonight is a usable Mac build: install it once, it runs from the menu bar with no Dock icon, 🤫 always shows bottom-left, and fn dictates into any app.

### Parity audit (main at 45e8bf4)

`docs/parity.md` was checked cell by cell against main at 45e8bf4. Work in open PRs counts for nothing until it merges. This redoes the 800cacc audit (#74) on the current ledger, and applies the cell moves that #90 (Linux steps) and #27 (iPhone steps) left to it.

| | Before (main at 45e8bf4) | After |
|---|---|---|
| Automated coverage | 10.2% (38 of 372: 18 n/a, 4 outside, 16 Mac hand-test) | 12.9% (48 of 372) |
| Confirmed coverage | 5.9% (22 of 372: 18 n/a, 4 outside) | 5.9%, the same |

Ten cells moved from `todo` to `hand-test`. Each has its tests on main and a step in `docs/manual-test.md`:
- **Linux** (#2 code, #90 steps): F01 (L-KEY-1 to L-KEY-3, L-FN-1, L-FN-3), F02 (L-FN-2), F19 (L-INS-1 to L-INS-5; Linux types the text and falls back to the clipboard without restore), F112 (L-FN-4).
- **iPhone** (#3, #27 and #54 code, #27 and #54 steps): F01 (I-DICT-1), F05 (I-IND-1, I-LA-1: the Live Activity landed in #27), F19 (I-DICT-1, I-FIELD-2), F27 (I-FIELD-1, I-FIELD-2: rule 8, #54), F53 (I-RET-1, I-BACKUP-1; the sweep still runs only while the app runs, #13), F108 (I-SETUP-1, I-KB-1, I-KB-2, I-MIC-1, I-DICT-1).

Checks:
- Every backticked test name in the ledger exists on main inside the class it names (Swift `func`, Rust `fn`), and every cited M-, I-, L- and MEET- step has a heading in `docs/manual-test.md`. A one-off script did the check; breaking one test name or one step id made it report that row. `scripts/parity.py` does not check hand steps yet (#102, open PR #116).
- Notes fixed: F01 Mac names the #112 🌐 key tests (M-SETUP-4, M-SETUP-5); F20 names `scripts/e2e-mac.sh --drop-paste` (#35); F72 gives the #40 numbers; F03, F04, F10, F21, F32, F53 and F66 name the open PR that builds the missing part.
- Linux F05 (🤫, #56) and F27 (rule 8, #58) are on main, but their hand steps are in `docs/linux.md`, not `docs/manual-test.md`, so they stay `todo` (#126).
- M-INS-4 still expects the failed-paste wording from before rule 8 (#57).
- The meetings PRs #73, #76, #77 and #89 merged into `feat/meetings` (#113), not main, so F65 to F73 are unchanged.
- No `impossible` cell was added: each needs an Apple doc URL and a substitute that is built.

### Next highest-value features (P0 still `todo`, per platform)

Pick from this list. It replaces the iteration 1 list under "Left".

- **Mac** (13 of 29 P0 cells are `todo`):
  - In open PRs, so review and merge them: F03 Esc cancel, F04 shortcuts, F10 max length, F21 paste and copy last (#47); F07 mic selection, F08 mic health, F12 languages, F39 dictionary (#39); F32 local cleanup model (#44).
  - No PR yet: F89 first-run onboarding (mic test, language, shortcut, try it); F99 crash recovery and relaunch; F88 screen and system-audio permissions (with meetings, #113); F91 the remaining hub tabs (after F39, F40, F37 and F55).
- **Linux** (25 of 29 P0 cells are `todo`):
  - Code on main, steps missing from `docs/manual-test.md`: F05 🤫 indicator (#56) and F27 rule 8 (#58) (#126).
  - In open PRs: F52 history and F53 24 h retention (#67); F03 Esc, F04 shortcuts, F10 cap, F21 paste last (#96, #67); F07 and F08 mic (#92); F32 cleanup and F109 insertion fit (#83); F39 dictionary (#86); F92 start at login (#114).
  - No PR yet: F06, F12, F17, F20, F23, F51, F88, F89, F90, F91, F99.
- **iPhone** (24 of 29 P0 cells are `todo`):
  - Mark the desktop-only P0 rows `impossible` where iOS forbids them, each with an Apple doc URL and a built substitute: F04, F17, F92 and F99 are candidates.
  - Then build F03 keyboard cancel and F10 duration warning (#13), F02 hands-free and F112 from the keyboard, F51 nonsense guard, F12 languages, F32 cleanup and F39 dictionary.

### summarizer (#129 and its Swift port)

| PR | State | What landed | Verified before merge |
|---|---|---|---|
| #129 | merged | Python action items: content-word recap dedupe, the next speaker as the "you" owner, job titles as names, request questions, five modal cue features, threshold 0.575 picked by 5-fold CV over train + dev. AMI test 16/20 role labels, 14/20 Speaker labels; CV 54.5% / 46.5% (#8 stays open) | 43 Python tests with the AMI cache, none skipped. 4 deliberate breaks (dedupe, addressee window, request questions, title aliases) each went red. Retraining reproduced `actions_model.json` byte for byte (sha1 15484b5c) and `eval test` gave the reported 16/20 and 14/20 |
| `feat/summary-v2-port` | open | The same changes in `Sources/ShepetalSummary`, the new weights as the bundled resource (threshold read from the file), `python_golden.json` regenerated, and 5 Swift tests that mirror the new Python tests case for case | `swift test` 218 pass with 0 skipped, also under `sandbox-exec` with only loopback allowed (the account tests need a stub server on 127.0.0.1). 7 deliberate breaks each went red. A one-off run on all 138 AMI scenario meetings, with role labels and with Speaker 1..4 labels, gave the same action items as Python in 276 of 276 (2,343 items: sentence, owner, task, due); it is not a committed test because the corpus is gitignored. `scripts/e2e-meeting.sh` OK (network denied for the app), and its 3 action items match Python's |

Left for the summarizer: action items with the right owner are 54.5% in CV, short of the 80% goal (#8). On the e2e meeting, "tomorrow morning" leaves "morning" in the task ("book the room morning"), in Python and Swift alike (#137).

### account (Mac sign-in, free trial, lifetime license, no model names in the UI)

| PR | State | What landed | Verified before merge |
|---|---|---|---|
| #70 | merged | Google sign-in for native apps with PKCE (RFC 8252 + RFC 7636) through ASWebAuthenticationSession: `/app/login` with S256 challenge and state, `shepetal://auth` callback with the state checked, `POST /api/app/token` (token in the Keychain, service `io.backant.shepetal.account`), license check at launch and every 24 h (never during a dictation; a starting dictation cancels it), cache in `account.json` (0600) with a 7-day offline grace, trial days left / "Yours forever" / "Trial ended" in the 🤫 menu and Home, Buy (Stripe Checkout), Check license now, Sign out. Signed out or expired, fn shows a hint instead of recording, but only in builds with `ShepetalRequiresSignIn` = true in Info.plist (off until shepetal.backant.io is live). Model names removed from every UI string (`EngineLabel`: "on-device speech recognition", "standard" / "alternative" engine; FluidAudio and process errors are logged and replaced by our own text). README's network sentence made precise | three independent review rounds. Round 1 FAIL (service missing, 5 should-fixes): fixed — re-check on a blocked fn press and after checkout, checkout 401 signs out, only web pages opened, plain speech errors, Keychain update-then-add, `App.swift` wiring pinned by `AccountWiringTests`, sign-in switch. Round 2 was cut short by the switch to Google PKCE sign-in. Round 3 FAIL (possible double resume of the sign-in continuation, a sign-in that could hang, wrong numbers here): fixed — resume-once guard, task cancellation closes the sheet, Cancel sign-in in the menu and Home, anchor window reused. My deliberate breaks (34) all went red. Reviewer breaks that stayed green, i.e. known gaps: the real `WebLogin` sheet (no test can open it), `checkCancellation` before storing the token (unreachable), source-match wiring tests that a reworded line would slip past, and model names built by string concatenation at run time. At the merge commit: `swift test` 162 pass, sandboxed `scripts/e2e-mac.sh` OK (WER 0.0%) |

Left for account: the web side must serve the same contract (`/app/login`, `POST /api/app/token`; on `feat/web` API.md still described the device flow when this merged). Turn on `ShepetalRequiresSignIn` in `scripts/make-app.sh` once shepetal.backant.io serves `/app/login` and `POST /api/app/token` (release session, issue below). Hand tests M-ACC-1 and M-ACC-2 need the live service (the ASWebAuthenticationSession sheet and its anchor in a menu-bar app can't run in a test without putting a window on screen). No screenshot: this shell has no Screen Recording permission. The 7-day offline grace applies to lifetime licenses too, as specified. Pavel can say if lifetime should be exempt.

### release (Mac build, installer, GitHub release)

**Shipped:** GitHub pre-release [v0.1.0-mac](https://github.com/backant-io/shepetal/releases/tag/v0.1.0-mac), built from main at 6298f40. Assets: `Shepetal-0.1.0.pkg` (the main download), `Shepetal-0.1.0-mac.zip`, and their `.sha256`. The notes give the click-by-click install and first run, the fn troubleshooting, the hand-test checklist and the known limits. Pavel's Mac runs this build from `/Applications/Shepetal.app`: the running copy was quit, the new one copied in, and the installer's postinstall run as his user. It printed "🌐 key already set to Do Nothing" and "login item: enabled", then opened the app (UIElement, 🤫 window at x=8, y=1143, 18×18). `SOAK=300 scripts/check-app.sh` on the release build (as the test bundle): alive with 🤫 after 296 s, then Quit from the menu, no crash report.

| PR | State | What landed | Verified before merge |
|---|---|---|---|
| #112 | merged (independent review running after the merge, because of the midnight deadline) | `.pkg` installer (`scripts/make-pkg.sh`, `scripts/pkg/{pre,post}install`): installs to /Applications. Its postinstall, as the logged-in user, sets "Press 🌐 key to" to Do Nothing (`defaults write com.apple.HIToolbox AppleFnUsageType -int 0`, `killall TextInputMenuAgent`, `killall -9 TextInputSwitcher`, read back), turns on Start at login (`Shepetal --postinstall`) and opens the app. The app does the same 🌐 check at every launch (only as `io.backant.shepetal`), shows a hint only on change, and has "Restore 🌐 key setting". "fn not received: re-grant Input Monitoring" next to 🤫 and in Home (`FnHealth`). `scripts/uninstall-mac.sh` (also in the app's Resources) keeps recordings. The menu item is renamed "Start at login" | `swift test` 123 pass (15 new: `FnKeySettingTests`, `FnHealthTests`; break of the store-once guard and the agent restart gives 5 red). `scripts/test-pkg-scripts.sh` OK against stand-ins (break: `killall` without -9 is red). The `--test` package installed with `installer -target CurrentUserHomeDirectory`, and both scripts ran in dry-run. e2e OK, check-app OK |
| #53 | merged | `make-app.sh` signs with the Apple Development identity (designated requirement = bundle ID + certificate, so permissions survive rebuilds), and `--install` puts the app in /Applications (quit with osascript, reopen). `--zip`. The 🤫 app icon is rendered by `scripts/make-icon.swift` at 16–1024 px. `scripts/check-app.sh` runs a separate test bundle `Shepetal Check.app` (`io.backant.shepetal.check`, ad-hoc) and checks UIElement, the 🤫 panel bottom-left, alive after `SOAK` s, and Quit from the real status menu (`--quit-from-menu-after`). README install steps; goal.md rule 1 (🌐 key), rule 3 (🤫 icon), M1 (installer) | partial independent review: blockers fixed (the check ran a permission-holding copy, false passes, lock path). `SOAK=300` passed; breaks of the Quit item, the status item title and the inset are each red. e2e OK |

**Left for release:**
- Act on the #112 review.
- Rebuild the release when #47 (Esc, shortcuts), #44 (cleanup model) and #39 (mic, languages) land.
- Notarization needs a Developer ID pair (#109).
- The screenshot of 🤫 needs Screen Recording for the worker, so it stays a hand test (M-IND-1).
- Hand tests M-SETUP-1..5 wait on Pavel.

### merge-b (review, fix and merge #36, #34, #44)

| PR | State | What landed | Verified before merge |
|---|---|---|---|
| #34 | merged | Insertion and system integration (Mac F06, F17, F27, F90, F92, F109 to `hand-test`). Rule 8 on the Mac (#42): the focused app and window are stored at fn-down, the text is pasted only if that window is still focused when it is ready, otherwise it stays on the clipboard (plain text with the Concealed/Transient markers, old clipboard not restored) with a ⌘V hint next to 🤫; FocusRestore removed, nothing refocuses another app. Also NBSP and selection rules, Secure Input notice and paste block, revoked-permission detection, Open at login (`SMAppService`, menu item), synthesized sounds | independent review PASS on a clean clone (4 deliberate breaks red); review fixes: an unreadable window still records the app (`PasteGateTests.testUnreadableWindowStillRecordsTheApp`, red when broken), 0.1 s AX timeout on the fn-down focus read, clipboard markers (red when dropped). After merging main: `swift test` 82 pass, sandboxed `scripts/e2e-mac.sh` OK, WER 0.0% |
| #36 | merged | Hub window (Home, History, Settings), history search, copy, playback, re-transcribe, archive, and the app and page URL of each dictation (Mac F23, F52 to `hand-test`; F91 stays `todo`). Issue #37 fixed in the review: history keeps only scheme, host and path of a URL (no query, fragment, userinfo, port or `;` path parameters) | independent review PASS on a clean clone; after merging main: `swift test` 46 pass, sandboxed `scripts/e2e-mac.sh` OK, WER 0.0% |

Left for merge-b: #44 (local cleanup model). #34 follow-ups are on #42 (same-app unreadable window pastes, tabs count as the same window, e2e activation-policy assert after #28) and #33 (background Secure Input owner blocks every paste, sound packs). #36 follow-ups are on #38 (one-way history upgrade, re-transcribe sharing the ASR actor, private windows, no hub UI test).

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
