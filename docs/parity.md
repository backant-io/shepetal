# Parity ledger: shepetal vs Wispr Flow

One row per feature ID in `docs/re/feature-inventory.md`, one column per shepetal platform. `python3 scripts/parity.py` checks this table and prints the coverage; the goal is 100% automated and 100% confirmed coverage (see `agent/goal.md`, "The finish line").

Last graded in iteration 1, against main at 60cc333 (see `docs/progress.md`). A cell is `done` only with a named test on main plus its PR, and `hand-test` only when a `docs/manual-test.md` step exists.

Platform mapping: Mac covers Wispr's Mac features, Linux covers Wispr's desktop features (Mac and Windows), iPhone covers Wispr's iOS features plus every desktop feature iOS allows.

Cell values:
- `todo`: not built yet.
- `done`: built and tested. The row's evidence for that platform names the test(s) in backticks and the PR that landed it on main, for example ``Mac: `HotkeyTests.testHoldStartsRecording` #12``.
- `hand-test`: everything automatable is done; the cell waits on a step in `docs/manual-test.md`.
- `confirmed`: set only by Pavel after he runs the hand test.
- `impossible`: the platform forbids it. The evidence for that platform cites the Apple, Linux or kernel doc by URL and names the substitute that was built.
- `n/a`: only for features that exist solely for Wispr's servers or business. The evidence reads `n/a <category>: <reason>`, with the category one of `billing`, `subscriptions`, `referrals`, `telemetry`, `remote-flags`, `ab-tests`, `account-admin`. Cloud-backed user features (sync, sharing, MCP, team dictionaries, cloud ASR) are never n/a; they get a local-first equivalent.

Evidence syntax: segments separated by `;`, each starting with `Mac:`, `Linux:`, `iPhone:` or `All:` (all three). Other text is a free note.

The completeness check (`--completeness /Users/sorcecoder/shepetal-re/identifier-map.tsv /Users/sorcecoder/shepetal-re/identifiers`) maps every Wispr identifier extracted by `python3 -I scripts/extract_identifiers.py` to an F-ID or to `internal` with a reason. The map and the identifier lists stay outside the repo.

| F-ID | Feature | Mac | Linux | iPhone | Evidence / notes |
|---|---|---|---|---|---|
| F01 | Push-to-talk on a hotkey (hold Fn by default) | hand-test | todo | todo | Mac: `FnGestureTests.testHoldTalksAndReleaseTranscribes`, `FnGestureTests.testHoldThresholdBoundary`, `FnGestureTests.testShortPressIsDroppedWithHint`, `FnGestureTests.testHintWordingAndDuration`, `DictationTests.testHoldHandsTheSamplesToTheTranscriber`, `DictationTests.testTooShortPressKeepsItsAudio`, `scripts/e2e-mac.sh` #10, `FnTapTests.testTapDisabledReleasesStaleFn`, `FnTapTests.testTapDisabledKeepsHeldFn`, `FnTapTests.testUserInputDisableAlsoReconciles`, `FnTapTests.testIdleDisableDoesNothing`, `FnTapTests.testOtherKeyWhileFnDownIsReported`, `FnTapTests.testGlobeKeyIsFn` #28, `PipelineTests.testPasteThatIsReadLands` #28, hand steps M-FN-1 and M-FN-3; iPhone: keyboard mic button and app handoff are on main (#3, `HandoffTests.testHappyPathInsertsTextExactlyOnce`), todo until its device steps are in docs/manual-test.md (#19) |
| F02 | Hands-free toggle (press once to start, again to stop) | hand-test | todo | todo | Mac: `FnGestureTests.testDoubleTapLocksHandsFreeAndTapEndsIt`, `FnGestureTests.testSecondPressAfterWindowIsNewHold`, `FnGestureTests.testKeysAfterTheChordWindowOrInHandsFreeKeepRecording` #10, `FnTapTests.testTapDisabledReleasesStaleFn`, `FnTapTests.testTapDisabledKeepsHeldFn`, `FnTapTests.testUserInputDisableAlsoReconciles`, `FnTapTests.testIdleDisableDoesNothing`, `FnTapTests.testOtherKeyWhileFnDownIsReported`, `FnTapTests.testGlobeKeyIsFn` #28, hand step M-FN-2 |
| F03 | Cancel or dismiss dictation (Esc) | todo | todo | todo | Mac: Esc cancel is not built (left for M2 in #10); iPhone: the app has a Cancel button (#3), the keyboard has none (#13) |
| F04 | Rebindable shortcuts, multi-key combos, mouse buttons | todo | todo | todo | |
| F05 | Floating Flow Bar / status pill with live waveform | hand-test | todo | todo | Mac: `IndicatorTests.testFrameIs18ptAnd8ptFromBottomLeftOfMainScreen`, `IndicatorTests.testLivePanelSitsInTheBottomLeftCorner`, `IndicatorTests.testLabelGrowsRightwardAndKeepsTheCorner`, `IndicatorTests.testPanelFlags`, `IndicatorTests.testPresentedOnceAndNeverHidden`, `IndicatorTests.testHintShowsThenHides`, `IndicatorTests.testModeRings` #28 on the 🤫 NSPanel from #10, hand step M-IND-1. Under goal rule 3 the fixed 🤫 and its ring states replace Wispr's draggable bar, its hide option and its 10-bar waveform (docs/re/dictation-input.md 2.8, settings `statusDockEdge` and `hideFlowBarPermanently`), so those are not built; iPhone: keyboard-corner 🤫 is tested (`IndicatorTests.testIndicatorIsInTheBottomLeftCornerWithTheStateNextToIt` #3), the Live Activity is not built (#13) |
| F06 | Start and stop sounds, haptics | hand-test | todo | todo | Mac: `ChimeTests.testEachSoundIsShortQuietAndFaded`, `ChimeTests.testSoundsDiffer`, `ChimeTests.testStartRisesStopFalls`, `ChimeTests.testTooShortTapIsSilent`, `ChimeTests.testFnShortcutIsSilent`, `ChimeTests.testCancelAfterAHeardStartPlaysCancel`, `ChimeTests.testDoubleTapPlaysLockThenStop` #34, hand step M-SND-1; one sound set with a toggle, packs and haptics deferred (#33) |
| F07 | Microphone selection with ranked fallback devices | hand-test | todo | todo | Mac: `MicTests.testForcedDeviceWins`, `MicTests.testForcedDeviceMissingFallsBackToRanking`, `MicTests.testRankingOrderPicksFirstPresent`, `MicTests.testNothingRankedUsesSystemDefault`, `MicTests.testClamshellSkipsBuiltIn`, `MicTests.testPreferMovesToTop`, `MicTests.testNewDeviceNoticedOnce` #39, hand steps M-MIC-1 and M-MIC-2 |
| F08 | Mic health alerts (no audio, disconnected, unreadable, AirPods or clamshell warnings) | hand-test | todo | todo | Mac: `MicTests.testFiveSecondsOfZerosWarnsOnce`, `MicTests.testRealAudioResetsTheSilenceCount`, `MicTests.testFifteenSecondsEscalates`, `MicTests.testNoBuffersInFiveSecondsStops`, `MicTests.testSilentStartReopensOnce`, `MicTests.testBluetoothHintOnce`, `MicTests.testQuietRecordingSuggestsCloserMic`, `MicTests.testClamshellWithOnlyBuiltInIsAnError` #39, hand steps M-MIC-2 to M-MIC-5 |
| F09 | Mute or pause media while dictating | todo | todo | todo | |
| F10 | Max dictation length and duration warnings | todo | todo | todo | Mac: no max-length cap yet (left for M2 in #10); iPhone: 5-minute cap on main (`DictationSessionTests.testRecordingStopsAtTheFiveMinuteCapAndIsKeptAndDelivered` #3), no duration warning |
| F11 | Whisper mode (quiet speech) | todo | todo | todo | |
| F12 | Multi-language with auto-detect | todo | todo | todo | Mac: routing between Parakeet and whisper large-v3-turbo is built (`LanguageTests.testEmptySelectionUsesTierPrimary`, `LanguageTests.testJapaneseRoutesToWhisperWithJa`, `LanguageTests.testMixedSetUsesWhisperAuto`, `LanguageTests.testWhisperArguments` #39, hand step M-LANG-1); todo until several languages are restricted to the selected set and large-v3-turbo has run (#31) |
| F13 | Streaming text while speaking | todo | todo | todo | |
| F14 | Mouse Flow (dictate via a mouse button) | todo | todo | todo | |
| F15 | BLE mic ring (hands-free over Bluetooth) | todo | todo | todo | |
| F16 | Jabra headset button and wear detection | todo | todo | todo | |
| F17 | Secure Input detection (warns when hotkeys are blocked) | hand-test | todo | todo | Mac: `WatchersTests.testSecureInputNoticeOnRisingEdgeOnly`, `WatchersTests.testSecureInputIgnoresShepetalItself`, `WatchersTests.testUnknownOwnerHasGenericWording`, `PasteGatePipelineTests.testSecureInputLeavesTheTextOnTheClipboard` #34, hand step M-SEC-1 |
| F18 | Slow-processing and degraded-network notices | todo | todo | todo | |
| F19 | Insert text into any app at the cursor (clipboard paste, then restore) | hand-test | todo | todo | Mac: `PasteCheckTests.testDataRequestedAfterCmdVMeansLanded`, `scripts/e2e-mac.sh` (paste landed, clipboard restored) #10, hand steps M-INS-1, M-INS-2 and M-INS-3 (Cmd+V into other apps needs Accessibility, #15); iPhone: `textDocumentProxy` insertion is on main (#3), todo until its device steps are in docs/manual-test.md (#19) |
| F20 | Paste verification and failed-paste fallback (copy, notify) | hand-test | todo | todo | Mac: `PasteCheckTests.testNoRequestWithinOneSecondMeansFailed`, `PasteCheckTests.testReadBeforeCmdVDoesNotCount` #10, `PipelineTests.testPasteNobodyReadsIsPasteFailed`, `PipelineTests.testPasteThatIsReadLands` #28, hand step M-INS-4 (Cmd+V into another app) |
| F21 | Paste last / copy last transcript shortcuts | todo | todo | todo | |
| F22 | Terminal and remote-desktop paste modes (Shift+Insert, typed paste) | todo | todo | todo | |
| F23 | App and URL awareness (active app, browser URL) | hand-test | todo | todo | Mac: `HistoryTests.testAppBundleAndUrlRoundTrip`, `HistoryTests.testBrowserBundleIds`, `scripts/e2e-mac.sh` (`history_app`, `history_bundle_id`, `history_url`, `app_resolve_ms`) #36, hand step M-CTX-1 (browser URL) |
| F24 | Textbox and AX context sent to the formatter (text around the cursor) | todo | todo | todo | |
| F25 | Screenshot / OCR context | todo | todo | todo | |
| F26 | Auto-learn words from the user's edits after paste | todo | todo | todo | |
| F27 | Focus restore before paste (store, then refocus the element) | hand-test | todo | todo | Mac, under rule 8 (paste only into the window that stayed in focus, never refocus, else the clipboard and a ⌘V hint): `PasteGateTests.testSameWindowPastes`, `PasteGateTests.testOtherAppOrWindowGoesToTheClipboard`, `PasteGateTests.testUnreadableFocusPastes`, `PasteGateTests.testUnreadableWindowStillRecordsTheApp`, `PasteGatePipelineTests.testFocusMovedWhileTranscribingLeavesTheTextOnTheClipboard`, `PasteGatePipelineTests.testUnknownFocusPastesAndRestoresTheClipboard` #34, hand step M-FOC-1 |
| F28 | Link memory: insert recently copied links by voice | todo | todo | todo | |
| F29 | IDE integration: file tagging (@file) in Cursor and other IDEs | todo | todo | todo | |
| F30 | Coding-CLI detection in terminals (claude, codex, aider and others) | todo | todo | todo | |
| F31 | Slack @-mention tagging | todo | todo | todo | |
| F32 | AI formatting / cleanup (filler removal, punctuation, casing) | todo | todo | todo | Mac: rule-based filler and stutter removal on main (`CleanupTests` #10); goal rule 5 needs a local-model cleanup (M2) |
| F33 | Per-app formatting override (raw vs AI per app) | todo | todo | todo | |
| F34 | Backtrack / self-correction ("no wait, I mean ...") | todo | todo | todo | |
| F35 | Smart lists and numbered lists | todo | todo | todo | |
| F36 | Email formatting and an auto email signature | todo | todo | todo | |
| F37 | Styles / tone per app category (work, email, personal, other) | todo | todo | todo | |
| F38 | "My voice" preferences and writing samples (tone match) | todo | todo | todo | |
| F39 | Personal dictionary (vocabulary and replacements) | todo | todo | todo | Mac: dictionary.txt replacements, casing and the whisper `--prompt` are built (`VocabularyTests.testReplacementIsWholeWordAndCaseInsensitive`, `VocabularyTests.testLongestPhraseFirst`, `VocabularyTests.testPromptPutsStarredFirstAndCapsAt200`, `VocabularyTests.testFileIsOwnerOnly`, `scripts/e2e-mac.sh` #39, hand step M-DICT-1); todo until Parakeet, the default model, gets the dictionary bias (#30) |
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
| F53 | Local data policy (store normally, delete after 24h, never store) | hand-test | todo | todo | Mac: `StorageTests.testRetentionKeepDeletesNothing`, `StorageTests.testRetention24hDeletesOnTime`, `StorageTests.testAudioIsOwnerOnly`, `StorageTests.testWavHoldsExactSamples` #10, hand step M-RET-1; iPhone: keep or delete after 24 h on main (`DictationSessionTests.testRecordingsAreKeptByDefaultAndDeletedAfter24hWhenChosen` #3), the sweep runs only while the app runs (#13), todo until its device steps are in docs/manual-test.md (#19) |
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
| F66 | Auto-detect meetings (Zoom, Meet, Teams, Slack huddles) and prompt to record | todo | todo | todo | Mac: MeetingDetector in meeting/ (`startsAfterFiveSecondGrace`, `browserNeedsMeetingTab`, `slackNeedsHuddleEvidence` #1), not used by the app, no prompt to record (#16) |
| F67 | Auto-start and auto-end recording (detect leaving the call, silence) | todo | todo | todo | Mac: detector start and end rules in meeting/ (`nativeReleaseEndsAfterReacquireWindow`, `noEndInFirstFifteenSeconds` #1), not wired to recording (#16) |
| F68 | Live transcript during the meeting | todo | todo | todo | |
| F69 | Post-meeting refined transcript | todo | todo | todo | |
| F70 | Speaker attribution and names (from the call UI and participants) | todo | todo | todo | |
| F71 | AI summary and notes (notepad merged with the transcript) | todo | todo | todo | All: extractive TextRank summarizer in summarize/ (#5), not used by any app (#18) |
| F72 | Action items / todos from meetings | todo | todo | todo | All: rule-based action items in summarize/ (#5) recover 4.4% of real AMI action items, the goal needs 80% (#8) |
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
| F88 | Permission onboarding (mic, accessibility with drag guidance, screen, system audio) | todo | todo | todo | Mac: Microphone, Input Monitoring and Accessibility window on main (#10, hand steps M-PERM-1 to M-PERM-4), no screen or system-audio permission yet |
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
| F108 | Mobile keyboard dictation (iPhone keyboard extension + app) | todo | todo | todo | iPhone: keyboard extension and app handoff on main (#3, `HandoffTests` and `DictationSessionTests`, 44 tests on the simulator), not run on a device (#13), todo until its device steps are in docs/manual-test.md (#19); Mac and Linux: iOS-only row with no allowed value (#20) |
| F109 | Smart spacing at insertion boundaries (leading or trailing space, nbsp, capitalization based on surrounding text) | hand-test | todo | todo | Mac: `InsertionRulesTests.testTrailingBoundarySpaceIsNBSP`, `InsertionRulesTests.testLeadingSpaceStaysASCII`, `InsertionRulesTests.testSelectionLowercaseIsMatched`, `InsertionRulesTests.testSelectionWithPeriodKeepsIt`, `InsertionRulesTests.testSelectionKeepsItsSpaces`, `InsertionRulesTests.testOnlyLastLineOfBeforeCounts` #34 (spacing and casing from #10), hand steps M-INS-5 and M-INS-6 |
| F110 | Formality mismatch detection (notices when the tone does not fit the app) | todo | todo | todo | |
| F111 | Feature tour / what's-new / changelog | todo | todo | todo | |
| F112 | Double-trigger debounce (ignores accidental double presses, conflicting shortcuts) | hand-test | todo | todo | Mac: `FnGestureTests.testRepeatedDownWhileHoldingIsIgnored`, `FnGestureTests.testShortcutWithFnCancels`, `DictationTests.testShortcutWithFnKeepsItsAudioAsCancelled` #10, hand step M-FN-4 |
| F113 | Team dictionary and snippets (shared with a team, scoped by department) | todo | todo | todo | |
| F114 | Creator mode: an optional on-screen label while dictating, for screen recordings and streams | todo | todo | todo | |
| F115 | Microphone advice quiz (environment and gear questions, a whisper try-out, a recommended mic setup) | todo | todo | todo | |
| F116 | Start dictation from the iPhone Action Button, with a setup guide and keyboard tips | todo | todo | todo | Mac and Linux: iOS-only row with no allowed value (#20) |
| F117 | Bulk import of dictionary words and snippets from a file, with a preview | todo | todo | todo | |
| F118 | Share usage stats as an image card (copy, save, post) | todo | todo | todo | |
| F119 | Meeting recorder from the keyboard (triple-tap of the dictation key, or a rebindable shortcut) | todo | todo | todo | |
| F120 | Meeting notes library in the hub with tabs and search | todo | todo | todo | |
| F121 | Keep or discard a very short or accidental meeting recording | todo | todo | todo | |
| F122 | Warn when the call app's mic differs from the one the meeting recorder captures | todo | todo | todo | |
| F123 | Latin-script view of non-Latin meeting transcripts | todo | todo | todo | |
| F124 | Prompt to move the app into Applications when launched from elsewhere | todo | todo | todo | |
