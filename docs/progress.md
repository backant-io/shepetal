# Progress

## Iteration 2 (2026-10-20 evening): six parallel sessions

Six sessions (release, merge-a, merge-b, quality, linux, ios) work from one shared clone. Each one keeps its own subsection here, newest merge first. Pavel's priority for tonight is a usable Mac build: install it once, it runs from the menu bar with no Dock icon, 🤫 always shows bottom-left, and fn dictates into any app.

### mac80 wave 3 (integration PR #INTPR)

- **Merged:** #246 (F13), #249 (F55), #245 (F40), #247 (F67), #248 (F81, F78, F120), #252 (F41), #258 (F38), #250 (F28, F36) and #251 (F124, F118, F18). Their hot-file wiring, wiring tests, manual steps and ledger rows came in #INTPR.
- **Mac column:** 69 of 124 cells counted before, 83 after. All 14 new cells are `hand-test`, waiting on M-LIVE-1, M-NOTE-1, M-SNIP-1, M-MTG-1 step 13, M-RET-2, M-MTG-12, M-TRN-1, M-VOICE-1, M-LINK-1, M-EMAIL-1, M-SLOW-1, M-SHARE-1 and M-MOVE-2.
- F67 Mac: `todo` to `hand-test` (#247): a meeting recording ends once no one has spoken for `meeting.silenceEnd` seconds (default 2 min) on every channel, decided once per live pass.
- **Composed in the wiring:** `finishText` runs a whole-dictation snippet first (F40), then the text step with My voice (F38), then the email layout (F36). In `process` a snippet is neither translated (F41) nor searched for "insert link" (F28), and translation runs before the link goes in, so a link never reaches the translator. Re-transcribe does the same.
- **For Pavel:** #259 (F28 and the pasteboard-privacy alert once macOS enforces it), #256 (notes are not in Export my data yet), F120's attendees wait on F70, F81 keeps the summary (Wispr's purge scope is unknown), and F38 sends every dictation through the cleanup model once a voice is set (its 700 ms bar with a voice is not measured).

### F24 on by default (Pavel, 2026-10-21)

- **Decision:** F24's latency bar is 800 ms instead of 700 ms, and "Use the text around the cursor to clean up dictation" is on by default with 500 characters on each side; Settings can still switch it off. Every other latency target stays at 700 ms.
- **Changed:** the default in `CleanupContext.isOn` and Settings, `scripts/e2e-mac.sh` c05 runs by default (FIELD=0 skips it) under an 800 ms bar, agent/goal.md, docs/models.md and M-CTX-2. There is no runtime fallback that skips the field when reading it is slow; the cleanup model's 1 s deadline is unchanged.
- **Mac column:** 68 of 124 cells counted before, 69 after: F24 is `hand-test`, waiting on M-CTX-2.

### mac80 wave 2 (integration PR #242)

- **Merged:** #230 (F91), #238 (F12), #229 (F71), #235 (F24), #234 (F42, F22), #233 (F48, F33), #236 (F86, F64), #232 (F61, F62) and #231 (F37). Their hot-file wiring, wiring tests, manual steps and ledger rows came in #242, with the #239 follow-ups (a failed model download says so next to 🤫, the whole menuNeedsUpdate body is pinned) and the window title in lowercase.
- **Mac column:** 56 of 124 cells counted before, 68 after. All 12 new cells are `hand-test`, waiting on M-LANG-1, M-HUB-2, M-HUB-6, M-HUB-7, M-HUB-8, M-STREAK-1, M-STYLE-1, M-FMT-1, M-INS-9, M-ENTER-1, M-MTG-9, M-EXP-1 and M-MCP-1.
- **F24 stays todo:** the code is in, behind a setting that is off by default, but `scripts/e2e-mac.sh` c05 (`FIELD=1`) is ready 726 to 800 ms after the release on the M4 Pro, over the 700 ms bar. Pavel decides: keep 500 characters each side, or try 250 (675 to 683 ms, accuracy not measured).

### mac80 wave 1 (integration PR #225)

- **Merged:** #209 (F66), #221 (F32, F34, F35; lands #44), #220 (F99), #222 (F39), #211 (F60), #216 (F114), #212 (F100), #217 (F93), #213 (F102), #218 (F09) and #219 (F111). Their hot-file wiring, wiring tests, manual steps and ledger rows came in #225.
- **Mac column:** 31 of 124 cells counted before, 44 after. All 13 new cells are `hand-test`, waiting on M-NEW-1, M-CRASH-1, M-CLEAN-1, M-CLEAN-2, M-DICT-2, M-BLOCK-1, M-CRT-1, M-MEDIA-1, M-STATS-1, M-NOTICE-1 and M-THEME-1 (F66 on M-MTG-1, M-MTG-2 and M-MTG-7).
- **For Pavel:** What's new… went to Home so the 🤫 menu keeps its 12 items (#210). The F102 switch had to stay in the menu, after Languages, which makes 13 items while an app is in front.

### windows (#118 follow-ups, PR #192; #140, PR #183)

- **Done in #192:** Tray > Recordings (keep, the default, or delete after 24 hours; pruned at launch, on pick and every minute), the 19/20 min length cap, transcripts kept as `<stamp>.txt` with Tray > Recent (click to copy), Tray > Hotkey (Ctrl+Win, Alt+Win, Shift+Win, F13), download progress on first run (a press says how far it is instead of a blue ring for minutes), and a failed `CreateMutexW` no longer starts a second instance. Settings live under `HKCU\Software\Shepetal`; the uninstaller removes them. Unit tests on Linux with deliberate breaks; hand steps 3, 6, 8, 12, 13 and 18 in windows/README.md, none run on a PC.
- **#183:** the short-press hint shows for 3 s on Windows and Linux, as on the Mac.
- **Left in #118:** a history window (search, replay, re-transcribe), text around the cursor (`text::fit`), signing, the hand test on a PC, and from the #80 review: the always-open mic, the DPI-unaware dialog and the first-run dialog behind other windows at autostart. Meeting items wait for the meetings effort; sign-in, trial and license are #149.

### Parity audit (main at 86bf3fa)

`docs/parity.md` was checked against every PR merged to main since the 45e8bf4 audit, through #39 and #138: #66, #83, #86, #92, #94, #96, #113, #129, #131, #134, #135, #136, #139, #142, #146, #148, #151, #152, #154 and #138 change cells or evidence. #39 brought its own ledger rows (Mac F07 and F08 to `hand-test`). #25, #74, #80, #116, #120, #122, #147 and #153 do not (CI, docs, the Windows app, tooling or summarizer quality). The Windows crates (#82, #87, #91, #108, #110) change no cell. Measured with `python3 scripts/parity.py`:

| | Before (main at 166e0f6) | After |
|---|---|---|
| Automated coverage | 13.4% (50 of 372) | 15.9% (59 of 372, two of them from #39) |
| Confirmed coverage | 8.6% (32 of 372) | 8.6%, the same |

Seven cells moved from `todo` to `hand-test`. Each has its tests on main and a step in `docs/manual-test.md`:
- **Mac** F65 meeting capture (#113, #135, #136; M-MTG-1, M-MTG-4, M-MTG-5, new M-MTG-6).
- **Linux** F03 Esc cancel (#96; L-SC-1, L-SC-2), F05 🤫 (#56; L-SETUP-5, L-IND-1 to L-IND-6, closes the gap in #126), F07 mic ranking (#92; L-MIC-1, L-MIC-2, L-MIC-5), F21 paste and copy last (#96; L-SC-3), F27 rule 8 (#58; L-FOC-1, L-FOC-2) and F65 meeting capture (#131; L-MEET-4, L-MEET-5, L-MEET-7, L-MEET-8).

New steps: M-INS-7 (#148), M-MTG-6 and M-MTG-7 (#113, #135, #146), and on Linux L-SETUP-5, L-SC-1 to L-SC-6, L-MIC-1 to L-MIC-6, L-VOC-1 to L-VOC-3, L-FOC-1 and L-FOC-2, L-IND-1 to L-IND-6 and L-MEET-4 to L-MEET-10, ported from `docs/linux*.md`. Stale step text was fixed in M-SETUP-1, M-INS-1, M-HUB-1, M-MTG-1, the Meetings intro, the Linux setup paragraph, L-FN-1, L-FN-4, L-INS-1, L-INS-2 and L-INS-5.

Merged but still `todo`, with the reason in the row:
- Mac meetings: F66 (#145 Screen Recording is never requested; #62 no Core Audio process-list fixture test), F68 (30 s passes with the dictation model, not a streaming model), F69 (no refined pass), F70 (no diarization or names), F71 (no notepad), F72 (cross-validation 54.5% with role labels, #8), F81 (no transcript retention), F82, F120, F121.
- Linux: F04 (no combo for the dictation key, no mouse buttons), F08 (no alert for a mic that sends no frames, no clamshell warning), F10 (the 20 min cap is not a setting), F32 (no local-model cleanup), F39 (Parakeet gets no word hint), F40 (no rich text), F109 (fit is never called, #81), F66 (the mic holder is the only evidence), F67 (no end on silence), F69 (no test of the final-pass model), F70, F71, F72, F81 (#141).

Checks: every backticked test name in the ledger exists on main inside the class it names (Swift `func`, Rust `fn`), each one added here was traced to its PR with `git log -S`, and every cited step id has a heading in `docs/manual-test.md`. Renamed tests were fixed: `FnTapTests.testGlobeKeyIsFn` is `testGlobeKeyEventsAreIgnored` (#139), and `evdev_key_values_become_gesture_events` is `evdev_key_events_reach_the_shortcut_layer_as_is` (#96).

### Mac hand test (Pavel, 2026-10-21, installed build 6298f40)

Pavel ran `docs/manual-test.md#mac` on the v0.1.0-mac build (`ShepetalCommit` 6298f40, the #112 merge). It predates #94 (fn gestures) and #113 (meetings), so the meeting steps could not work there. His report: M-FN-2 does not work, M-FN-3 starts hands-free, M-INS-1 capitalizes and adds a period mid-sentence, M-NS-1 "no focus ... took forever to realize the window changed", M-MTG-1 and M-MTG-2 do not detect Zoom or a browser meeting. Everything else on the Mac works.

A Mac `hand-test` cell moved to `confirmed` only when every hand step it cites passed and every PR its Mac evidence cites is an ancestor of 6298f40. Measured with `python3 scripts/parity.py` against main at 10edd42:

| | Before | After |
|---|---|---|
| Automated coverage | 13.4% (50 of 372) | 13.4%, the same |
| Confirmed coverage | 6.7% (25 of 372: 21 n/a, 4 outside) | 8.6% (32 of 372) |

- **Confirmed (7):** F05 (M-IND-1), F17 (M-SEC-1), F23 (M-CTX-1), F53 (M-RET-1), F90 (M-PERM-5), F92 (M-LOGIN-1), F112 (M-FN-4). Their PRs (#10, #28, #34, #36) are all in 6298f40. Since then main changed the fn tap timestamps (#94) and added the red meeting ring to 🤫 (#113). F112's gesture logic and F05's dictation rings are the same.
- **Failed steps, still `hand-test`:** F01 (M-FN-3), F02 (M-FN-2), F19 (M-INS-1), F51 (M-NS-1). #94 landed after 6298f40, and PR #139 handles M-FN-2 and M-FN-3.
- **Still `hand-test` because his report touches them:**
  - F109 (M-INS-5, M-INS-6): his M-INS-1 failure is F109's casing rule, and M-INS-5 runs through the same `InsertionRules.fit`.
  - F20 (M-INS-4) and F27 (M-FOC-1): his M-NS-1 note names M-INS-4's setup ("no text field has focus") and the rule 8 notice "The window changed while you spoke" (`PasteGate.focusMoved`).
  - F52 (M-HUB-2 to M-HUB-5): his copy of `docs/manual-test.md` heads M-HUB-4 "(failing with different model)". Without the whisper.cpp fallback, "Re-transcribe failed" is the expected result, so it needs his word.
- No Mac `hand-test` cell cites a PR after 6298f40. The meeting rows F65 to F67 are still `todo` even though #113 has merged. Moving them is for the next audit, and his M-MTG results do not count because his build had no meetings.

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
- **Linux** (24 of 29 P0 cells are `todo`):
  - Code on main, steps missing from `docs/manual-test.md`: F05 🤫 indicator (#56) and F27 rule 8 (#58) (#126).
  - In open PRs: F52 history and F53 24 h retention (#67); F03 Esc, F04 shortcuts, F10 cap, F21 paste last (#96, #67); F07 and F08 mic (#92); F32 cleanup and F109 insertion fit (#83); F39 dictionary (#86); F92 start at login (#114).
  - No PR yet: F12, F17, F20, F23, F51, F88, F89, F90, F91, F99.
- **iPhone** (23 of 29 P0 cells are `todo`):
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
| #124 | merged | Follow-up to #70 from the PR review: `POST /api/checkout` answers 409 `already_active` once the user has bought (web/API.md on feat/web-e2e). The app showed "Checkout failed: The account service answered 409"; now `AccountError.alreadyBought` makes Buy re-check the license, so the menu shows "Yours forever" and no second checkout opens | `testBuyWhenAlreadyBoughtChecksAndShowsYoursForever` and the 409 case in `testCheckoutReturnsTheStripeURL`; removing the re-check turns the controller test red. After merging main (86bf3fa): `swift test` 279 pass |

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

### merge-a (review, fix and merge #28, #40, #24, #25, #39, #47; issues #75, #78, #79)

A takeover session finished the last PRs after the self-hosted worker's token ran out at about 00:40 on 2026-10-21.

| PR | State | What landed | Verified before merge |
|---|---|---|---|
| #28 | merged | Automated tests for the Mac shell paths (🤫 panel frame and flags, `paste_failed`, empty transcript, tap re-enable) and the F51 guard. A run of the e2e that stops partway fails | four review rounds, the last one PASS; 108 tests; sandboxed e2e OK |
| #40 | merged | AMI-trained action-item detection for the summarizer (65% with the right owner, under the 80% goal; #129 later raised it, and #8 is still open) | independent review |
| #24, #25 | merged | Outside cells in the parity ledger. CI and `scripts/ci/run-checks.sh` | re-reviews PASS; Actions green |
| #39 | merged | Mic choice with ranking, mic health alerts, language routing and the personal dictionary. Merged with main's off-main-thread mic: the mic opens on the Recorder's queue, the device choice and health checks run on top, and an open that fails ends the dictation. Speech errors use main's plain wording, so no model names reach the UI | review findings fixed (merge, model names, re-transcribe dictionary test); 271 tests, only the then-known #133 failure; sandboxed e2e WER 0.0%; CI green apart from #133 |
| #47 | merged | Esc cancel, rebindable shortcuts, a 20 min cap with a 1 min warning, paste last and copy last. Also these review fixes: the key tap runs on its own thread, a hidden key-up no longer blocks fn, typing and app chords are refused, stored chords are validated, paste last goes through the secure-input gate. Globe 179 is ignored (#139), and the ending tap of hands-free transcribes on its press | 317 tests, 0 failures; sandboxed e2e OK; deliberate breaks red; CI green |
| #163 | merged | #78: FluidAudio stays in offline mode, so a model it cannot load is never deleted and downloaded again. Only the menu's download lifts that mode | `OfflineModelTests` (a broken cache survives; red when offline mode is off); 280 tests; e2e OK |
| #168 | merged | #75: every dictation goes through Apple's sound-isolation effect before the model, the WAV stays raw, and voice processing and the Mic Mode picker are never used. Knob: `voiceIsolationMix` | `VoiceIsolationTests`; 320 tests; e2e WER 3.1% (was 0.0%), ready 131–218 ms (was 59–85) |

#79 (fn timed by when the main thread handles it) was fixed on main by #94 and is closed.

**Left for merge-a:**
- Hand tests: M-ESC, M-KEY, M-LEN, M-LAST (#47), M-MIC-1..6 and M-LANG-1 (#39, #168).
- The 20 min forced stop shows no hint next to 🤫 and no marker on the history row (#47 review nit).
- Voice isolation costs accuracy on clean synthetic speech. M-MIC-6 decides whether real rooms need `voiceIsolationMix` 50.
- Meetings and the whisper.cpp engine still hear raw audio.

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
