# Parity ledger: shepetal vs Wispr Flow

One row per feature ID in `docs/re/feature-inventory.md`, one column per shepetal platform. `python3 scripts/parity.py` checks this table and prints the coverage; the goal is 100% automated and 100% confirmed coverage (see `agent/goal.md`, "The finish line").

Last audited against main at 45e8bf4 (2026-10-20, see `docs/progress.md`). A cell is `done` only with a named test on main plus its PR, and `hand-test` only when the automatable part is on main and a `docs/manual-test.md` step exists. Work in open PRs counts for nothing until it merges.

Platform mapping: Mac covers Wispr's Mac features, Linux covers Wispr's desktop features (Mac and Windows), iPhone covers Wispr's iOS features plus every desktop feature iOS allows.

Cell values:
- `todo`: not built yet.
- `done`: built and tested. The row's evidence for that platform names the test(s) in backticks and the PR that landed it on main, for example ``Mac: `HotkeyTests.testHoldStartsRecording` #12``.
- `hand-test`: everything automatable is done; the cell waits on a step in `docs/manual-test.md`.
- `confirmed`: set only by Pavel after he runs the hand test.
- `impossible`: the platform forbids it. The evidence for that platform cites the Apple, Linux or kernel doc by URL and names the substitute that was built.
- `n/a`: only for features that exist solely for Wispr's servers or business. The evidence reads `n/a <category>: <reason>`, with the category one of `billing`, `subscriptions`, `referrals`, `telemetry`, `remote-flags`, `ab-tests`, `account-admin`, or `declined` for a feature Pavel ruled out (name the date). Cloud-backed user features (sync, sharing, MCP, team dictionaries, cloud ASR) are never n/a; they get a local-first equivalent.
- `outside`: the cell's platform is outside the platform mapping for this feature. Allowed only for a Mac or Linux cell whose inventory Wispr column has no `M` or `W` (an iOS-only feature); the inventory row is the evidence. An iPhone cell is never `outside`: an iOS-forbidden feature is `impossible`.

Evidence syntax: segments separated by `;`, each starting with `Mac:`, `Linux:`, `iPhone:` or `All:` (all three). Other text is a free note.

The completeness check (`--completeness /Users/sorcecoder/shepetal-re/identifier-map.tsv /Users/sorcecoder/shepetal-re/identifiers`) maps every Wispr identifier extracted by `python3 -I scripts/extract_identifiers.py` to an F-ID or to `internal` with a reason. The map and the identifier lists stay outside the repo.

| F-ID | Feature | Mac | Linux | iPhone | Evidence / notes |
|---|---|---|---|---|---|
| F01 | Push-to-talk on a hotkey (hold Fn by default) | hand-test | hand-test | hand-test | Mac: `FnGestureTests.testHoldTalksAndReleaseTranscribes`, `FnGestureTests.testHoldThresholdBoundary`, `FnGestureTests.testShortPressIsDroppedWithHint`, `FnGestureTests.testHintWordingAndDuration`, `DictationTests.testHoldHandsTheSamplesToTheTranscriber`, `DictationTests.testTooShortPressKeepsItsAudio`, `scripts/e2e-mac.sh` #10, `FnTapTests.testTapDisabledReleasesStaleFn`, `FnTapTests.testTapDisabledKeepsHeldFn`, `FnTapTests.testUserInputDisableAlsoReconciles`, `FnTapTests.testIdleDisableDoesNothing`, `FnTapTests.testOtherKeyWhileFnDownIsReported`, `FnTapTests.testGlobeKeyIsFn` #28, `PipelineTests.testPasteThatIsReadLands` #28, `FnKeySettingTests.testChangeInputSourceIsSetToDoNothingAndSaysSo`, `FnKeySettingTests.testPreviousValueIsStoredOnlyOnce`, `FnKeySettingTests.testRestorePutsBackTheOldValueOnceAndForgetsIt`, `FnHealthTests.testPressTheTapNeverReportsAlertsOnceAfterGrace` #112 (the 🌐 key set to Do Nothing, rule 1), hand steps M-FN-1, M-FN-3, M-SETUP-4 and M-SETUP-5; Linux: evdev fn daemon on main (#2, `default_hotkey_is_fn`, `fn_is_bit_464_of_the_sysfs_key_bitmap`, `daemon_waits_for_fn_only_on_keyboards_that_can_send_it`, `hold_of_500ms_is_push_to_talk`, `release_at_499ms_is_a_tap_not_a_stop`, `single_tap_is_too_short_once_window_expires`, `too_short_press_keeps_the_clip_and_shows_the_hint`, `dictation_keeps_the_audio_the_model_heard`, `evdev_key_values_become_gesture_events`), never run on a desktop, hand steps L-KEY-1, L-KEY-2, L-KEY-3, L-FN-1 and L-FN-3 (#90); iPhone: keyboard mic button and app handoff (#3, `HandoffTests.testHappyPathInsertsTextExactlyOnce`, `HandoffTests.testMicDoesNotStartWithoutAKeyboardRequest`), hand step I-DICT-1 (#27) |
| F02 | Hands-free toggle (press once to start, again to stop) | hand-test | hand-test | todo | Mac: `FnGestureTests.testDoubleTapLocksHandsFreeAndTapEndsIt`, `FnGestureTests.testSecondPressAfterWindowIsNewHold`, `FnGestureTests.testKeysAfterTheChordWindowOrInHandsFreeKeepRecording` #10, `FnTapTests.testTapDisabledReleasesStaleFn`, `FnTapTests.testTapDisabledKeepsHeldFn`, `FnTapTests.testUserInputDisableAlsoReconciles`, `FnTapTests.testIdleDisableDoesNothing`, `FnTapTests.testOtherKeyWhileFnDownIsReported`, `FnTapTests.testGlobeKeyIsFn` #28, hand step M-FN-2; Linux: double-tap latch on main (#2, `double_tap_gap_is_500ms`, `double_tap_inside_window_is_hands_free_until_next_press`, `second_press_after_window_starts_fresh`), hand step L-FN-2 (#90) |
| F03 | Cancel or dismiss dictation (Esc) | todo | todo | todo | Mac: Esc cancel is in open PR #47, not on main; Linux: Esc only cancels as a chord while fn is held (L-FN-4), not in hands-free, and the Esc key is in open PR #96; iPhone: the app has a Cancel button (#3), the keyboard has none (#13) |
| F04 | Rebindable shortcuts, multi-key combos, mouse buttons | todo | todo | todo | Mac: in open PR #47, not on main; Linux: `SHEPETAL_KEY` picks one key on main (#2, `a_numeric_key_is_named_key_n_in_the_hint`, L-KEY-3), with no combos or mouse buttons |
| F05 | Floating Flow Bar / status pill with live waveform | hand-test | todo | hand-test | Mac: `IndicatorTests.testFrameIs18ptAnd8ptFromBottomLeftOfMainScreen`, `IndicatorTests.testLivePanelSitsInTheBottomLeftCorner`, `IndicatorTests.testLabelGrowsRightwardAndKeepsTheCorner`, `IndicatorTests.testPanelFlags`, `IndicatorTests.testPresentedOnceAndNeverHidden`, `IndicatorTests.testHintShowsThenHides`, `IndicatorTests.testModeRings` #28 on the 🤫 NSPanel from #10, hand step M-IND-1. Under goal rule 3 the fixed 🤫 and its ring states replace Wispr's draggable bar, its hide option and its 10-bar waveform (docs/re/dictation-input.md 2.8, settings `statusDockEdge` and `hideFlowBarPermanently`), so those are not built; Linux: the 🤫 indicator is on main (#56, `every_indicator_gets_the_state_and_late_ones_the_current_one`, `the_indicator_is_started_again_when_it_exits`), todo until its steps move from docs/linux.md to docs/manual-test.md (#126); iPhone: keyboard-corner 🤫 (`IndicatorTests.testIndicatorIsInTheBottomLeftCornerWithTheStateNextToIt` #3, `IndicatorTests.testStateRingUsesTheMacColors`, `HandoffTests.testKeyboardIndicatorFollowsTheSession` #27) and the Live Activity / Dynamic Island (`DictationSessionTests.testLiveActivityFollowsTheDictationAndEndsWhenTheTextIsDelivered`, `DictationSessionTests.testLiveActivityShowsAFailureAndACancelEndsIt`, `DictationSessionTests.testSupersededRecordingDoesNotEndTheNewRecordingsLiveActivity`, `IndicatorTests.testLiveActivityGoesStaleOnlyAfterTheStatesTimeout` #27), hand steps I-IND-1 and I-LA-1 |
| F06 | Start and stop sounds, haptics | n/a | n/a | n/a | All: n/a declined: Pavel had all sounds removed (2026-10-21) as annoying; the 🤫 ring colors show the state, and haptics are not planned |
| F07 | Microphone selection with ranked fallback devices | todo | todo | todo | |
| F08 | Mic health alerts (no audio, disconnected, unreadable, AirPods or clamshell warnings) | todo | todo | todo | |
| F09 | Mute or pause media while dictating | todo | todo | todo | |
| F10 | Max dictation length and duration warnings | todo | todo | todo | Mac: max length with a warning is in open PR #47, not on main; iPhone: 5-minute cap on main (`DictationSessionTests.testRecordingStopsAtTheFiveMinuteCapAndIsKeptAndDelivered` #3), no duration warning |
| F11 | Whisper mode (quiet speech) | todo | todo | todo | |
| F12 | Multi-language with auto-detect | todo | todo | todo | |
| F13 | Streaming text while speaking | todo | todo | todo | |
| F14 | Mouse Flow (dictate via a mouse button) | todo | todo | todo | |
| F15 | BLE mic ring (hands-free over Bluetooth) | todo | todo | todo | |
| F16 | Jabra headset button and wear detection | todo | todo | todo | |
| F17 | Secure Input detection (warns when hotkeys are blocked) | hand-test | todo | todo | Mac: `WatchersTests.testSecureInputNoticeOnRisingEdgeOnly`, `WatchersTests.testSecureInputIgnoresShepetalItself`, `WatchersTests.testUnknownOwnerHasGenericWording`, `PasteGatePipelineTests.testSecureInputLeavesTheTextOnTheClipboard` #34, hand step M-SEC-1 |
| F18 | Slow-processing and degraded-network notices | todo | todo | todo | |
| F19 | Insert text into any app at the cursor (clipboard paste, then restore) | hand-test | hand-test | hand-test | Mac: `PasteCheckTests.testDataRequestedAfterCmdVMeansLanded`, `scripts/e2e-mac.sh` (paste landed, clipboard restored) #10, hand steps M-INS-1, M-INS-2 and M-INS-3 (Cmd+V into other apps needs Accessibility, #15); Linux: typed insertion on main (#2, `session_type_picks_native_typer`, `gnome_wayland_skips_wtype`, `ydotool_then_clipboard_are_fallbacks`, `text_goes_over_stdin_not_argv`): Linux types the text (xdotool, wtype, ydotool) and falls back to the clipboard without restore, not clipboard paste plus restore, hand steps L-INS-1 to L-INS-5 (#90); iPhone: `textDocumentProxy` insertion (#3, `HandoffTests.testHappyPathInsertsTextExactlyOnce`, `HandoffTests.testResultForTheSameFieldIsInserted` #54), hand steps I-DICT-1 and I-FIELD-2 |
| F20 | Paste verification and failed-paste fallback (copy, notify) | hand-test | todo | todo | Mac: `PasteCheckTests.testNoRequestWithinOneSecondMeansFailed`, `PasteCheckTests.testReadBeforeCmdVDoesNotCount` #10, `PipelineTests.testPasteNobodyReadsIsPasteFailed`, `PipelineTests.testPasteThatIsReadLands` #28, `scripts/e2e-mac.sh` (`--drop-paste`: the text stays on the clipboard and history says `paste_failed`) #35, hand step M-INS-4 (Cmd+V into another app; its expected wording predates rule 8, #57) |
| F21 | Paste last / copy last transcript shortcuts | todo | todo | todo | Mac: in open PR #47, not on main; Linux: in open PRs #67 and #96 |
| F22 | Terminal and remote-desktop paste modes (Shift+Insert, typed paste) | todo | todo | todo | |
| F23 | App and URL awareness (active app, browser URL) | hand-test | todo | todo | Mac: `HistoryTests.testAppBundleAndUrlRoundTrip`, `HistoryTests.testBrowserBundleIds`, `scripts/e2e-mac.sh` (`history_app`, `history_bundle_id`, `history_url`, `app_resolve_ms`) #36, hand step M-CTX-1 (browser URL) |
| F24 | Textbox and AX context sent to the formatter (text around the cursor) | todo | todo | todo | |
| F25 | Screenshot / OCR context | todo | todo | todo | |
| F26 | Auto-learn words from the user's edits after paste | todo | todo | todo | |
| F27 | Focus restore before paste (store, then refocus the element) | hand-test | todo | hand-test | Mac, under rule 8 (paste only into the window that stayed in focus, never refocus, else the clipboard and a ⌘V hint): `PasteGateTests.testSameWindowPastes`, `PasteGateTests.testOtherAppOrWindowGoesToTheClipboard`, `PasteGateTests.testUnreadableFocusPastes`, `PasteGateTests.testUnreadableWindowStillRecordsTheApp`, `PasteGatePipelineTests.testFocusMovedWhileTranscribingLeavesTheTextOnTheClipboard`, `PasteGatePipelineTests.testUnknownFocusPastesAndRestoresTheClipboard` #34, hand step M-FOC-1; Linux: the focus check is on main (#58, `only_the_same_window_gets_the_text`, `session_picks_how_focus_is_read`), todo until its steps move from docs/linux.md to docs/manual-test.md (#126); iPhone, under rule 8 (a result for a different field goes to the clipboard): `HandoffTests.testResultForAnotherFieldIsCopiedNotInserted`, `HandoffTests.testCopyLeavesThePlainTextOnThePasteboardWithoutRestoringTheOldOne`, `HandoffTests.testClipboardWriteThatDidNotLandSaysTheTextIsInHistory` #54, hand steps I-FIELD-1 and I-FIELD-2 |
| F28 | Link memory: insert recently copied links by voice | todo | todo | todo | |
| F29 | IDE integration: file tagging (@file) in Cursor and other IDEs | todo | todo | todo | |
| F30 | Coding-CLI detection in terminals (claude, codex, aider and others) | todo | todo | todo | |
| F31 | Slack @-mention tagging | todo | todo | todo | |
| F32 | AI formatting / cleanup (filler removal, punctuation, casing) | todo | todo | todo | Mac: rule-based filler and stutter removal on main (`CleanupTests` #10); the local-model cleanup that goal rule 5 needs is in open PR #44, not on main |
| F33 | Per-app formatting override (raw vs AI per app) | todo | todo | todo | |
| F34 | Backtrack / self-correction ("no wait, I mean ...") | todo | todo | todo | |
| F35 | Smart lists and numbered lists | todo | todo | todo | |
| F36 | Email formatting and an auto email signature | todo | todo | todo | |
| F37 | Styles / tone per app category (work, email, personal, other) | todo | todo | todo | |
| F38 | "My voice" preferences and writing samples (tone match) | todo | todo | todo | |
| F39 | Personal dictionary (vocabulary and replacements) | todo | todo | todo | |
| F40 | Snippets (voice shortcut expands to text, rich text) | todo | todo | todo | |
| F41 | Translate while dictating | todo | todo | todo | |
| F42 | Voice commands: "press enter" | todo | todo | todo | |
| F43 | Command Mode / instruct (voice-edit selected text, ask, act) | todo | todo | todo | |
| F44 | "Hey Flow" wake phrase for command mode | todo | todo | todo | |
| F45 | Polish: rewrite the selected text from a hotkey with saved prompts | todo | todo | todo | |
| F46 | Polish diff view and undo | todo | todo | todo | |
| F47 | Auto-polish after dictation | todo | todo | todo | |
| F48 | Undo AI (revert to the raw transcript) | todo | todo | todo | |
| F49 | Flow Lens: ask about the screen or context via a shortcut chat | todo | todo | todo | |
| F50 | Stacked messages: in personal messaging apps, one dictation is split into several chat messages | todo | todo | todo | |
| F51 | Nonsense or empty transcript guard | hand-test | todo | todo | Mac: `PipelineTests.testEmptyTranscriptPastesNothingAndKeepsAudio`, `PipelineTests.testFillerOnlyTranscriptIsNoSpeech`, `PipelineTests.testWhisperBlankTagIsNoSpeech`, `PipelineTests.testSilentRecordingNeverReachesTheModel`, `SpeechGuardTests.testLevelOfSilenceNoiseAndToneAgainstTheFloor`, `SpeechGuardTests.testShortQuietWordInALongRecordingIsSpeech`, `SpeechGuardTests.testStripsNonSpeechTags`, `scripts/e2e-mac.sh` silent run #28, hand step M-NS-1. Built: the hold threshold as the minimum speech duration, a level gate (-60 dBFS, UserDefaults `speechFloorDb`) in place of a VAD model, and non-speech tag stripping, outcome `no_speech`. The floor is set on `say` audio only, so it waits on the real-mic calibration in M-NS-1, and a VAD model comes in if one floor does not fit real mics; iPhone: under 0.3 s never reaches the model (`DictationSessionTests.testTooShortRecordingIsKeptMarkedAndTheKeyboardIsTold` #3), no nonsense guard |
| F52 | Dictation history with search, copy, retry, archive, audio playback | hand-test | todo | todo | Mac: `HistoryTests.testOldDatabaseUpgradesWithoutLosingRows`, `HistoryTests.testSearchMatchesTextAndRawTextCaseInsensitively`, `HistoryTests.testSearchEscapesWildcards`, `HistoryTests.testSearchIsNewestFirstAndLimited`, `HistoryTests.testArchivedHiddenUnlessAsked`, `HistoryTests.testUpdateKeepsAudioCreatedAtAndOutcome`, `StorageTests.testReadReturnsTheExactSavedSamples`, `StorageTests.testRetryNeedsTheAudio`, `scripts/e2e-mac.sh` (re-transcribe from the kept WAV, `retranscribed_model`) #36, hand steps M-HUB-2 to M-HUB-5; iPhone: history list on main (#3), no replay or re-transcription (#13) |
| F53 | Local data policy (store normally, delete after 24h, never store) | hand-test | todo | hand-test | Mac: `StorageTests.testRetentionKeepDeletesNothing`, `StorageTests.testRetention24hDeletesOnTime`, `StorageTests.testAudioIsOwnerOnly`, `StorageTests.testWavHoldsExactSamples` #10, hand step M-RET-1; Linux: every recording is kept owner-only (#2, `recording_is_private_and_always_kept`, `an_audio_dir_open_to_others_is_refused`, L-AUD-1 to L-AUD-4), but there is no delete-after-24 h option, which is in open PR #67; iPhone: keep or delete after 24 h (`DictationSessionTests.testRecordingsAreKeptByDefaultAndDeletedAfter24hWhenChosen` #3, `AudioArchiveTests.testSweepDeletesOnlyRecordingsOlderThanTheAge`, `AudioArchiveTests.testAudioIsExcludedFromICloudAndDeviceBackup`, `AudioArchiveTests.testFilesAreWrittenWithCompleteProtection`), the sweep runs only while the app runs (#13), hand steps I-RET-1 and I-BACKUP-1 |
| F54 | Feedback on a transcript (thumbs, desired text) | todo | todo | todo | |
| F55 | Scratchpad notes window (tabs, pinning, open from a shortcut) | todo | todo | todo | |
| F56 | Note version history and AI transforms on notes | todo | todo | todo | |
| F57 | Images in notes | todo | todo | todo | |
| F58 | Shareable note links | todo | todo | todo | |
| F59 | Cloud sync across devices | todo | todo | todo | |
| F60 | Stats: words dictated, WPM, time saved, per-app usage | todo | todo | todo | |
| F61 | Daily streak and milestones | todo | todo | todo | |
| F62 | Insights heatmap and "voice profile" persona card | todo | todo | todo | |
| F63 | Team leaderboard | todo | todo | todo | |
| F64 | Data export (self-serve) | todo | todo | todo | |
| F65 | Meeting recorder: mic + system audio capture | todo | todo | todo | Mac: process-tap capture to Me.wav and Others.wav in meeting/ (`meetingAudioIsOwnerOnly`, `captureFailuresAreReported` #1), not used by the app and not run on hardware (#16) |
| F66 | Auto-detect meetings (Zoom, Meet, Teams, Slack huddles) and prompt to record | todo | todo | todo | Mac: MeetingDetector in meeting/ (`startsAfterFiveSecondGrace`, `browserNeedsMeetingTab`, `slackNeedsHuddleEvidence` #1), not used by the app, no prompt to record (#16; the app wiring is in open PR #113); Linux: one-shot `pw-dump` parser in `shepetal probe` on main (#2, `finds_meeting_apps_on_the_mic`, `ignores_idle_streams_monitors_playback_and_itself`, `system_audio_is_default_sink_monitor`, L-MEET-1 to L-MEET-3), no live watch and no prompt to record |
| F67 | Auto-start and auto-end recording (detect leaving the call, silence) | todo | todo | todo | Mac: detector start and end rules in meeting/ (`nativeReleaseEndsAfterReacquireWindow`, `noEndInFirstFifteenSeconds` #1), not wired to recording (#16) |
| F68 | Live transcript during the meeting | todo | todo | todo | |
| F69 | Post-meeting refined transcript | todo | todo | todo | |
| F70 | Speaker attribution and names (from the call UI and participants) | todo | todo | todo | |
| F71 | AI summary and notes (notepad merged with the transcript) | todo | todo | todo | All: extractive TextRank summarizer in summarize/ (#5), not used by any app (#18) |
| F72 | Action items / todos from meetings | todo | todo | todo | All: AMI-trained action items in summarize/ (#40) find 65% of the AMI test split's items with the right owner when speakers have role labels and 40% with Speaker 1 to 4 labels (docs/summarization.md); the goal needs 80% (#8), and no app on main uses the summarizer yet (#18) |
| F73 | Ask questions about meetings (chat) | todo | todo | todo | |
| F74 | Calendar integration (Google, Microsoft), upcoming-meeting reminders | todo | todo | todo | |
| F75 | Pre-read briefs before a meeting | todo | todo | todo | |
| F76 | Recording consent notice posted to the meeting chat | todo | todo | todo | |
| F77 | Auto-share notes with participants | todo | todo | todo | |
| F78 | Folders for meetings | todo | todo | todo | |
| F79 | Automations on meetings or notes | todo | todo | todo | |
| F80 | Import from Granola / Otter | todo | todo | todo | |
| F81 | Transcript retention policy | todo | todo | todo | |
| F82 | Hide the recorder in screen share; split-screen next to the call; menu-bar meeting control | todo | todo | todo | |
| F83 | Long-meeting check-in and max length | todo | todo | todo | |
| F84 | Meeting translation | todo | todo | todo | |
| F85 | Org insights (team-level analytics over meetings) | n/a | n/a | n/a | All: n/a account-admin: org-level insights exist for team admins of Wispr org accounts; shepetal has no accounts or orgs. |
| F86 | MCP server exposing notes and meetings to AI clients | todo | todo | todo | |
| F87 | Connectors / connect apps (e.g. Atlassian, Loom) for context | todo | todo | todo | |
| F88 | Permission onboarding (mic, accessibility with drag guidance, screen, system audio) | todo | todo | todo | Mac: Microphone, Input Monitoring and Accessibility window on main (#10, hand steps M-PERM-1 to M-PERM-4), no screen or system-audio permission and no automated test of the window |
| F89 | Onboarding: mic test, language, shortcut, try-it-yourself | todo | todo | todo | |
| F90 | Permission-revoked detection and re-prompt | hand-test | todo | todo | Mac: `WatchersTests.testFirstObservationIsNotARevocation`, `WatchersTests.testRevokedReportedOnce`, `WatchersTests.testRegrantClears`, `WatchersTests.testRegrantAfterRevocationIsReportedOnce`, `WatchersTests.testGrantAfterLaunchIsNotARestore` #34, hand step M-PERM-5; fn tap after an Input Monitoring re-grant is #32 |
| F91 | Hub main window (home, history, dictionary, snippets, styles, notes, settings) | todo | todo | todo | Mac: Home, History and Settings tabs only (#36, hand steps M-HUB-1 and M-HUB-6), with no automated UI test (#38); dictionary, snippets, styles and notes tabs come with F39, F40, F37 and F55 |
| F92 | Launch at login, hide the Dock icon, menu-bar presence | hand-test | todo | todo | Mac: menu-bar item and no Dock icon (LSUIElement) on main (#10), Open at login through `SMAppService.mainApp` with `WatchersTests.testLoginStatusMapping` #34, hand step M-LOGIN-1 |
| F93 | Dark mode / theme | todo | todo | todo | |
| F94 | UI localization | todo | todo | todo | |
| F95 | Focus mode (block distracting apps and URLs) | todo | todo | todo | |
| F96 | Typing reminder (nudges you to use voice when you type a lot) | todo | todo | todo | |
| F97 | Deep links (`wispr-flow://`) for login and actions | todo | todo | todo | |
| F98 | Auto-updater (deferred while dictating) | todo | todo | todo | |
| F99 | Helper crash recovery and relaunch | todo | todo | todo | |
| F100 | In-app notifications center (tips, server announcements) | todo | todo | todo | |
| F101 | Extensions / agent tool bridge (spawns external agent CLIs) | todo | todo | todo | |
| F102 | Admin app deny-list (dictation blocked in some apps) | todo | todo | todo | |
| F103 | HIPAA mode / enterprise data controls | n/a | n/a | n/a | All: n/a account-admin: HIPAA BAA and enterprise data controls are org-account administration; shepetal sends no data anywhere. |
| F104 | Accounts, SSO, team administration | n/a | n/a | n/a | All: n/a account-admin: sign-in, SSO and team management exist only for Wispr accounts; shepetal is a single-user local app. Team dictionary and snippets are F113. |
| F105 | Subscriptions, trials, weekly word limit, referrals, student plan, paywalls | n/a | n/a | n/a | All: n/a subscriptions: plans, trials, word limits, referrals and paywalls only serve Wispr's billing; shepetal is free and local. |
| F106 | Product analytics, session telemetry, Sentry, Datadog logs | n/a | n/a | n/a | All: n/a telemetry: product analytics and crash/log upload only serve Wispr; shepetal keeps logs local. |
| F107 | Remote feature flags and A/B experiments | n/a | n/a | n/a | All: n/a remote-flags: remote feature flags and A/B experiments only serve Wispr; shepetal uses compile-time features. |
| F108 | Mobile keyboard dictation (iPhone keyboard extension + app) | outside | outside | hand-test | iPhone: keyboard extension and app handoff (#3, `HandoffTests.testHappyPathInsertsTextExactlyOnce`, `HandoffTests.testMicDoesNotStartWithoutAKeyboardRequest`, `DictationSessionTests.testOneKeyboardRequestStartsTheMicOnce`, `DictationSessionTests.testDeniedMicPermissionTellsTheKeyboard`), not yet run on a device (#13), hand steps I-SETUP-1, I-KB-1, I-KB-2, I-MIC-1 and I-DICT-1 (#27); Mac and Linux: outside, Wispr ships it on iOS only (inventory Wispr column `i`) |
| F109 | Smart spacing at insertion boundaries (leading or trailing space, nbsp, capitalization based on surrounding text) | hand-test | todo | todo | Mac: `InsertionRulesTests.testTrailingBoundarySpaceIsNBSP`, `InsertionRulesTests.testLeadingSpaceStaysASCII`, `InsertionRulesTests.testSelectionLowercaseIsMatched`, `InsertionRulesTests.testSelectionWithPeriodKeepsIt`, `InsertionRulesTests.testSelectionKeepsItsSpaces`, `InsertionRulesTests.testOnlyLastLineOfBeforeCounts` #34 (spacing and casing from #10), hand steps M-INS-5 and M-INS-6 |
| F110 | Formality mismatch detection (notices when the tone does not fit the app) | todo | todo | todo | |
| F111 | Feature tour / what's-new / changelog | todo | todo | todo | |
| F112 | Double-trigger debounce (ignores accidental double presses, conflicting shortcuts) | hand-test | hand-test | todo | Mac: `FnGestureTests.testRepeatedDownWhileHoldingIsIgnored`, `FnGestureTests.testShortcutWithFnCancels`, `DictationTests.testShortcutWithFnKeepsItsAudioAsCancelled` #10, hand step M-FN-4; Linux: a chord cancels and keeps the clip, autorepeat is ignored (#2, `chord_with_another_key_cancels`, `cancel_keeps_the_recording`, `evdev_key_values_become_gesture_events`), hand steps L-FN-4 and L-FN-1 (#90) |
| F113 | Team dictionary and snippets (shared with a team, scoped by department) | todo | todo | todo | |
| F114 | Creator mode: an optional on-screen label while dictating, for screen recordings and streams | todo | todo | todo | |
| F115 | Microphone advice quiz (environment and gear questions, a whisper try-out, a recommended mic setup) | todo | todo | todo | |
| F116 | Start dictation from the iPhone Action Button, with a setup guide and keyboard tips | outside | outside | todo | Mac and Linux: outside, Wispr ships it on iOS only (inventory Wispr column `i`) |
| F117 | Bulk import of dictionary words and snippets from a file, with a preview | todo | todo | todo | |
| F118 | Share usage stats as an image card (copy, save, post) | todo | todo | todo | |
| F119 | Meeting recorder from the keyboard (triple-tap of the dictation key, or a rebindable shortcut) | todo | todo | todo | |
| F120 | Meeting notes library in the hub with tabs and search | todo | todo | todo | |
| F121 | Keep or discard a very short or accidental meeting recording | todo | todo | todo | |
| F122 | Warn when the call app's mic differs from the one the meeting recorder captures | todo | todo | todo | |
| F123 | Latin-script view of non-Latin meeting transcripts | todo | todo | todo | |
| F124 | Prompt to move the app into Applications when launched from elsewhere | todo | todo | todo | |
