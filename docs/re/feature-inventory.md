# Wispr Flow 1.6.1174: master feature inventory for shepetal

One line per user-visible feature. The depth lives in the sibling docs: `/Users/sorcecoder/github/backant/shepetal/docs/re/dictation-input.md`, `insertion-context.md`, `text-pipeline.md`, `meetings.md`, `mobile-and-platforms.md`, `app-architecture.md`.

Evidence keys (short): **S** = `prefs.user` setting key in `~/Library/Application Support/Wispr Flow/config.json`; **N** = notification type in `config.json` `notifications`; **F** = feature flag string in `.webpack/main/index.js`; **T** = flow.sqlite table; **H** = HelperAPI message; **K** = shortcut action id in `prefs.user.shortcuts`; **P** = onboarding page id.

Platforms: M = macOS, W = Windows, i = iPhone (mobile details in `mobile-and-platforms.md`; i is marked only where Wispr documents it). Cloud = whether Wispr needs its servers for the feature. Priority: P0 = core dictation, P1 = meetings and major features, P2 = nice-to-have, Skip = billing, growth or telemetry (listed so nothing is silently dropped).

## Core dictation and input

| ID | Feature | Wispr | Cloud | shepetal plan (local) | Pri | Evidence |
|---|---|---|---|---|---|---|
| F01 | Push-to-talk on a hotkey (hold Fn by default) | M W i | y | CGEventTap / evdev hotkey, then local ASR (whisper.cpp or Parakeet) | P0 | K `ptt`; H `KeypressEvent` |
| F02 | Hands-free toggle (press once to start, again to stop) | M W | y | same pipeline, latch mode | P0 | K `popo`; S `tutorials.usedHandsfree` |
| F03 | Cancel or dismiss dictation (Esc) | M W | n | cancel the capture; keep the audio, marked cancelled in history | P0 | K `dismiss`; N `TranscriptCancelled` |
| F04 | Rebindable shortcuts, multi-key combos, mouse buttons | M W | n | key-combo settings UI, chord parser | P0 | S `shortcuts`, `modifierShortcut`; F `MultiKeybindService` |
| F05 | Floating Flow Bar / status pill with live waveform | M W | n | small always-on-top non-activating panel | P0 | renderer `status`; S `statusDockEdge`, `hideFlowBarPermanently`; F `can-drag-flow-bar` |
| F06 | Start and stop sounds, haptics | M W | n | bundled own sounds, optional | P0 | H `PlayDictationStartSound`, `FireHaptic`; S `enableSounds`, `selectedSoundFolder` |
| F07 | Microphone selection with ranked fallback devices | M W | n | CoreAudio / PipeWire device list | P0 | S `overrideAudioDeviceId`, `rankedAudioDevices`; N `MicSwitched`, `NewMicDetected` |
| F08 | Mic health alerts (no audio, disconnected, unreadable, AirPods or clamshell warnings) | M W | n | RMS check plus device events | P0 | N `NoAudio*`, `MicDisconnected`, `AirPodsWarning`, `NoClamshellBuiltInMic`, `SuggestWiredMic` |
| F09 | Mute or pause media while dictating | M W | n | MediaRemote / MPRIS pause, then resume | P1 | S `shouldMuteAudio`, `shouldPauseAudio`; H `IsMediaPlayingUpdate` |
| F10 | Max dictation length and duration warnings | M W | n | configurable cap, chunked ASR | P0 | N `DictationDurationWarning`, `DictationMaxDurationReached` |
| F11 | Whisper mode (quiet speech) | M W i | y | gain normalization plus a VAD threshold tweak | P1 | S `tutorials.usedWhisperMode` |
| F12 | Multi-language with auto-detect | M W i | y | Whisper language ID, restricted to the user's set | P0 | S `selectedLanguages`, `effectiveLanguages`; N `WrongLanguageSetting` |
| F13 | Streaming text while speaking | M W | y | streaming partials from local ASR | P1 | F `stream-text` |
| F14 | Mouse Flow (dictate via a mouse button) | M W | n | mouse-button hotkey | P2 | N `MouseFlowDiscovery`; e2e `connectMouse` |
| F15 | BLE mic ring (hands-free over Bluetooth) | M | y | skip unless hardware appears | P2 | H `Ble*`, `BLEAudioData`; F `ble-mic-ring` |
| F16 | Jabra headset button and wear detection | M W | n | HID button as hotkey | P2 | S `jabraWearDetectionEnabled`; dep `@gnaudio/jabra-js` |
| F17 | Secure Input detection (warns when hotkeys are blocked) | M | n | `IsSecureEventInputEnabled` poll | P0 | H `SecureInputStatus`; N `SecureInputBlockingShortcuts` |
| F18 | Slow-processing and degraded-network notices | M W | y | local latency notice only | P2 | N `ProcessingDelayNotification`, `DegradedNetwork`; S `processingDelayNotificationEnabled` |

## Insertion and context

| ID | Feature | Wispr | Cloud | shepetal plan (local) | Pri | Evidence |
|---|---|---|---|---|---|---|
| F19 | Insert text into any app at the cursor (clipboard paste, then restore) | M W i | n | pasteboard + synthesized Cmd+V, then restore the clipboard; AX insert fallback | P0 | H `PasteText`, `PasteOutcome`; F `DisableClipboardRestore` |
| F20 | Paste verification and failed-paste fallback (copy, notify) | M W | n | AX read-back of the textbox | P0 | H `DictatedTextVerification`; N `PasteFailed`, `PasteBlocked` |
| F21 | Paste last / copy last transcript shortcuts | M W | n | keep the last result in memory | P0 | K `paste_last_text`, `copy_last_text`; N `SuggestPasteLastText` |
| F22 | Terminal and remote-desktop paste modes (Shift+Insert, typed paste) | M W | n | per-app insert strategy table | P1 | F `ShiftInsert`, `RemoteViewerPaste` |
| F23 | App and URL awareness (active app, browser URL) | M W | n | NSWorkspace + AX URL read | P0 | H `AppContextUpdate`, `AppInfoUpdate`; T `History.app`, `.url` |
| F24 | Textbox and AX context sent to the formatter (text around the cursor) | M W | y | local LLM prompt context, opt-in | P1 | H `GetTextBoxInfo`, `CursorContextUpdate`, `AccessibilityTreeHTML`; S `useAxContext` |
| F25 | Screenshot / OCR context | M W | y | Vision OCR locally, opt-in, off by default | P2 | S `shouldOCRScreenCapture`; T `History.screenshot` |
| F26 | Auto-learn words from the user's edits after paste | M W | y | AX diff of the textbox after paste, then add to the dictionary | P1 | H `UpdateEditedText`; S `shouldAutoLearnWords`; N `LearnedDictionaryWords` |
| F27 | Focus restore before paste (store, then refocus the element) | M W | n | AX focused element cache | P0 | H `StoreFocusedAppAndElement`, `FocusStoredAppAndElement` |
| F28 | Link memory: insert recently copied links by voice | M W | n | clipboard watcher into a `Links` table | P2 | T `Links`; H `ClipboardChanged` |
| F29 | IDE integration: file tagging (@file) in Cursor and other IDEs | M W | y | AX read of editor tabs, local fuzzy match | P2 | S `ideFileTagging`, `cursorIdeIntegration`; N `FirstFileTaggingCelebration` |
| F30 | Coding-CLI detection in terminals (claude, codex, aider and others) | M | n | process-tree check, then code-friendly formatting | P2 | F `CodingCLIDetection`; enum `CodingCLIAgent` |
| F31 | Slack @-mention tagging | M W | y | skip | P2 | F `slack-tagging`; H `GetSelectedTextViaCopy` copy mode slack |

## Text pipeline and personalization

| ID | Feature | Wispr | Cloud | shepetal plan (local) | Pri | Evidence |
|---|---|---|---|---|---|---|
| F32 | AI formatting / cleanup (filler removal, punctuation, casing) | M W i | y | small local LLM or rules; raw-ASR fallback | P0 | S `aiFormatting`, `autoCleanup.level`; F `auto-cleanup-v0` |
| F33 | Per-app formatting override (raw vs AI per app) | M W | n | per-app rules in settings | P1 | S `appTranscriptionFormats`, `defaultTranscriptionFormat` |
| F34 | Backtrack / self-correction ("no wait, I mean ...") | M W i | y | LLM prompt rule plus a regex pre-pass | P1 | N `SmartFormattingBacktrack` |
| F35 | Smart lists and numbered lists | M W i | y | LLM or rules | P1 | N `SmartFormattingList` |
| F36 | Email formatting and an auto email signature | M W | y | per-app template | P2 | N `SmartFormattingEmails`; S `emailAutoSignature`, `emailSignatureOption` |
| F37 | Styles / tone per app category (work, email, personal, other) | M W i | y | local LLM style presets keyed by app category | P1 | S `personalizationStyles`, `styleDetectionEnabled`; F `style-personalization` |
| F38 | "My voice" preferences and writing samples (tone match) | M W | y | few-shot samples in the local LLM prompt | P2 | T `UserVoicePreferences`, `UserContext`; F `my-voice` |
| F39 | Personal dictionary (vocabulary and replacements) | M W i | n | ASR prompt bias plus post-replace | P0 | T `Dictionary` |
| F40 | Snippets (voice shortcut expands to text, rich text) | M W i | n | `Dictionary.isSnippet` equivalent | P1 | T `Dictionary.isSnippet`, `replacementHtml`; F `rich-text-snippets` |
| F41 | Translate while dictating | M W | y | local LLM translation | P2 | N `FeatureTranslate` |
| F42 | Voice commands: "press enter" | M W | n | trailing-phrase rule, then synthesize Return | P1 | S `pressEnterCommandEnabled` |
| F43 | Command Mode / instruct (voice-edit selected text, ask, act) | M W | y | local LLM over the selection; tools later | P1 | S `commandModeEnabled`; T `InstructHistory`; N `UsingCommandMode` |
| F44 | "Hey Flow" wake phrase for command mode | M W | y | local wake-word (openWakeWord) | P2 | N `UseHeyFlowForCommandMode` |
| F45 | Polish: rewrite the selected text from a hotkey with saved prompts | M W | y | local LLM, prompt presets | P1 | K `polish`, `polish_prompt_1`; T `Polish`; S `polishInstructions` |
| F46 | Polish diff view and undo | M W | n | diff-match-patch style view | P2 | K `view_diff`; T `Polish.polishUndone` |
| F47 | Auto-polish after dictation | M W | y | optional second LLM pass | P2 | S `autoPolishAfterDictation` |
| F48 | Undo AI (revert to the raw transcript) | M W | n | keep raw + formatted, toggle | P1 | T `History.hasRevertedAI` |
| F49 | Flow Lens: ask about the screen or context via a shortcut chat | M W | y | local VLM, optional | P2 | K `lens`; T `FlowLensHistory` |
| F50 | Stacked messages: in personal messaging apps, one dictation is split into several chat messages | M W | y | split on sentence or LLM boundaries, send each with Return | P2 | S `stackedMessagesEnabled` (only applies to the PERSONAL app type, in the `index.js` formatter path) |
| F51 | Nonsense or empty transcript guard | M W | n | min speech duration + VAD | P0 | N `TranscriptionEmpty`, `VoidDictation`; F `nonsense-transcription-toast` |

## History, notes, stats

| ID | Feature | Wispr | Cloud | shepetal plan (local) | Pri | Evidence |
|---|---|---|---|---|---|---|
| F52 | Dictation history with search, copy, retry, archive, audio playback | M W i | n | SQLite `History`, FTS5 search; raw audio of every dictation saved locally (owner-only dir, never uploaded) for replay and re-transcription | P0 | T `History` |
| F53 | Local data policy (store normally, delete after 24h, never store) | M W | n | keep (default) or delete after 24h; no "never store" option, the raw audio of every dictation is always saved on device | P0 | S `localDataPolicy` |
| F54 | Feedback on a transcript (thumbs, desired text) | M W | y | local only, feeds the dictionary | P2 | T `History.feedback`, `desiredFormatted` |
| F55 | Scratchpad notes window (tabs, pinning, open from a shortcut) | M W | n | Markdown notes in SQLite | P1 | renderer `scratchpad`; T `Notes`; F `scratchpad` |
| F56 | Note version history and AI transforms on notes | M W | y | versions table + local LLM | P2 | T `NoteVersions.transformPrompt` |
| F57 | Images in notes | M W | n | local blobs | P2 | T `NoteImages` |
| F58 | Shareable note links | M W | y | export to a file instead | Skip | T `SharedNotes`; host `notes.wisprflow.ai` |
| F59 | Cloud sync across devices | M W i | y | optional later (Syncthing / iCloud folder) | P2 | S `cloudSync`; F `cloud-sync`, `enable-sync-ws` |
| F60 | Stats: words dictated, WPM, time saved, per-app usage | M W i | n | SQL over `History` | P1 | index `idx_history_per_app_stats`; hub `wpm` |
| F61 | Daily streak and milestones | M W | n | local streak calc | P2 | F `daily-streak`; S `notificationSettings.milestonesAndProgress` |
| F62 | Insights heatmap and "voice profile" persona card | M W | y | local aggregates, no LLM persona | P2 | `config.json` `voiceProfile`; N `InsightsReady` |
| F63 | Team leaderboard | M W | y | none | Skip | F `pro-team-leaderboard` |
| F64 | Data export (self-serve) | M W | y | local export (JSON/CSV/Markdown) | P1 | F `member-self-serve-data-export` |

## Meetings / notetaker (detail in `meetings.md`)

| ID | Feature | Wispr | Cloud | shepetal plan (local) | Pri | Evidence |
|---|---|---|---|---|---|---|
| F65 | Meeting recorder: mic + system audio capture | M W | n | Core Audio process tap / ScreenCaptureKit; PipeWire on Linux | P1 | renderer `meeting_recorder`; H `GetSystemAudioStatus`; F `meeting-recorder` |
| F66 | Auto-detect meetings (Zoom, Meet, Teams, Slack huddles) and prompt to record | M W | n | mic-holder + window/AX heuristics | P1 | H `GetMicrophoneHolders`, `GetMeetingTabScan`; S `autoDetectMeetingsEnabled` |
| F67 | Auto-start and auto-end recording (detect leaving the call, silence) | M W | n | leave-button / mic-release detection | P1 | S `notetakerAutoStartEnabled`, `notetakerAutoEndEnabled`; H `BrowserLeaveProof` |
| F68 | Live transcript during the meeting | M W | y | streaming local ASR | P1 | S `notetakerLiveTranscriptEnabled` |
| F69 | Post-meeting refined transcript | M W | y | batch local ASR (larger model) after the call | P1 | T `Meetings.refineStatus` |
| F70 | Speaker attribution and names (from the call UI and participants) | M W | y | local diarization + AX active-speaker | P1 | H `MeetingSpeakerChange`; S `notetakerAttributeNamesEnabled` |
| F71 | AI summary and notes (notepad merged with the transcript) | M W | y | local LLM summary | P1 | T `Meetings.summary`, `.notes`; S `notetakerNotepadOnStart` |
| F72 | Action items / todos from meetings | M W | y | local LLM extraction into `Todos` | P1 | T `Todos`; F `todos` |
| F73 | Ask questions about meetings (chat) | M W | y | local RAG over transcripts | P1 | T `NotetakerChats`, `NotetakerChatMessages`; F `ask-skills` |
| F74 | Calendar integration (Google, Microsoft), upcoming-meeting reminders | M W | y | read EventKit / ICS locally | P2 | T `CalendarEvents`; S `notetakerCalendarNotificationsEnabled`; F `notetaker-microsoft-calendar` |
| F75 | Pre-read briefs before a meeting | M W | y | local LLM over past notes | P2 | T `CalendarEvents.prereadSummary`; F `preread-config` |
| F76 | Recording consent notice posted to the meeting chat | M W | n | optional AX chat post | P2 | H `PostConsentChatMessage`; S `notetakerCalendarNotice` |
| F77 | Auto-share notes with participants | M W | y | none (export) | Skip | S `notetakerAutoShareNotes` |
| F78 | Folders for meetings | M W | n | local folders | P2 | T `Folders`, `FolderMeetings`; F `notetaker-folders` |
| F79 | Automations on meetings or notes | M W | y | local hooks (run a script on summary) | P2 | T `Automations`; F `automations` |
| F80 | Import from Granola / Otter | M W | y | file import | P2 | T `GranolaImportRun`; S `granolaImported`, `otterImported` |
| F81 | Transcript retention policy | M W | n | local retention setting | P1 | S `notetakerTranscriptRetention` |
| F82 | Hide the recorder in screen share; split-screen next to the call; menu-bar meeting control | M W | n | window sharingType=none; layout helper | P2 | S `hideMeetingRecorderInScreenShare`, `notetakerSplitScreenJoinEnabled`, `notetakerMenuBarMeetingEnabled` |
| F83 | Long-meeting check-in and max length | M W | n | timer prompts | P2 | S `notetakerLongMeetingCheckInEnabled`, `notetakerMaxRecordingLength` |
| F84 | Meeting translation | M W | y | local LLM | P2 | N `NotetakerTranslationIntroModal` |
| F85 | Org insights (team-level analytics over meetings) | M W | y | none | Skip | S `notetakerOrgInsightsDefault`; F `org-insights` |
| F86 | MCP server exposing notes and meetings to AI clients | M W | y | local stdio MCP over SQLite | P1 | dep `@modelcontextprotocol/sdk`; S `notetakerMCPVisibilityState` |
| F87 | Connectors / connect apps (e.g. Atlassian, Loom) for context | M W | y | none initially | P2 | `e2e:setConnectorCatalog`; P `connect-apps` |

## App shell, onboarding, system

| ID | Feature | Wispr | Cloud | shepetal plan (local) | Pri | Evidence |
|---|---|---|---|---|---|---|
| F88 | Permission onboarding (mic, accessibility with drag guidance, screen, system audio) | M W i | n | step-by-step checks + System Settings deep links | P0 | renderer `accessibility_drop`; deep links `Privacy_Microphone`, `Privacy_Accessibility`, `Privacy_ScreenCapture` |
| F89 | Onboarding: mic test, language, shortcut, try-it-yourself | M W i | n | 4-step first-run | P0 | P `microphone-test`, `language`, `shortcut`, `try-it-yourself` |
| F90 | Permission-revoked detection and re-prompt | M W | n | poll on wake / focus | P0 | N `MicrophonePermissionRevoked`, `AccessibilityPermissionRevoked` |
| F91 | Hub main window (home, history, dictionary, snippets, styles, notes, settings) | M W | n | single settings/history window | P0 | renderer `hub` |
| F92 | Launch at login, hide the Dock icon, menu-bar presence | M W | n | SMAppService / XDG autostart | P0 | S `openAtLogin`, `hideAppInDock` |
| F93 | Dark mode / theme | M W | n | follow the system | P2 | S `theme`; F `dark-mode` |
| F94 | UI localization | M W i | n | i18n later | P2 | S `uiLocale`; F `localization-framework`; dep `i18next` |
| F95 | Focus mode (block distracting apps and URLs) | M W | n | out of scope | Skip | S `focusModeEnabled`, `focusModeBlockedApps`; H `SetFocusMode` |
| F96 | Typing reminder (nudges you to use voice when you type a lot) | M W | n | optional | P2 | N `TypingReminderEnabled` |
| F97 | Deep links (`wispr-flow://`) for login and actions | M W | n | `shepetal://` for settings | P2 | `setAsDefaultProtocolClient("wispr-flow")` |
| F98 | Auto-updater (deferred while dictating) | M W | y | opt-in GitHub Releases updater | P1 | `autoUpdater.setFeedURL` dl.wisprflow.com; F `defer-updates-while-active` |
| F99 | Helper crash recovery and relaunch | M W | n | supervise the helper, restart with backoff | P0 | `index.js` helper launcher `relaunchCount`; N `HelperPersistentFailure` |
| F100 | In-app notifications center (tips, server announcements) | M W | y | local error toasts only | P2 | T `RemoteNotifications`; S `notificationSettings` |
| F101 | Extensions / agent tool bridge (spawns external agent CLIs) | M | y | later plugin hook | P2 | `agentToolBridge.js`; F `extension-system` |
| F102 | Admin app deny-list (dictation blocked in some apps) | M W | y | local per-app disable list | P1 | N `AppDictationBlocked`; F `app-deny-list-enforcement` |
| F103 | HIPAA mode / enterprise data controls | M W | y | moot (all local) | Skip | `cache.hipaaBaaSigned`; N `HipaaCloudSyncGate` |
| F104 | Accounts, SSO, teams, team dictionary / snippets | M W i | y | none (single-user local) | Skip | deps supabase, workos; T `Dictionary.teamDictionaryId`; F `department-scoped-snippets` |
| F105 | Subscriptions, trials, weekly word limit, referrals, student plan, paywalls | M W i | y | none | Skip | N `WeeklyWordsLimitReached`, `ProTrialUpgradeCTA`; F `student-plan-free` |
| F106 | Product analytics, session telemetry, Sentry, Datadog logs | M W i | y | none: local logs only | Skip | posthog, segment, sentry, datadog hosts in `index.js` |
| F107 | Remote feature flags and A/B experiments | M W i | y | compile-time features | Skip | about 230 flags in the `index.js` enum |
| F108 | Mobile keyboard dictation (iPhone keyboard extension + app) | i | y | see `mobile-and-platforms.md` | P1 | `mobile-and-platforms.md` |
| F109 | Smart spacing at insertion boundaries (leading or trailing space, nbsp, capitalization based on surrounding text) | M W | n | read the characters around the cursor via AX, then adjust | P0 | F `trailing-boundary-nbsp`; H `TextBoxInfo` |
| F110 | Formality mismatch detection (notices when the tone does not fit the app) | M W | y | none | P2 | N `FormalityMismatchDetected` |
| F111 | Feature tour / what's-new / changelog | M W | n | release notes page | P2 | renderer `feature_tour`; event `changelog_opened` |
| F112 | Double-trigger debounce (ignores accidental double presses, conflicting shortcuts) | M W | n | debounce in the hotkey state machine | P0 | N `Debounce`, `DictationCancelledOtherShortcut` |

## Counts
- P0: F01, F02, F03, F04, F05, F06, F07, F08, F10, F12, F17, F19, F20, F21, F23, F27, F32, F39, F51, F52, F53, F88, F89, F90, F91, F92, F99, F109, F112 = **29**
- P1: F09, F11, F13, F22, F24, F26, F33, F34, F35, F37, F40, F42, F43, F45, F48, F55, F60, F64, F65, F66, F67, F68, F69, F70, F71, F72, F73, F81, F86, F98, F102, F108 = **32**
- P2: F14, F15, F16, F18, F25, F28, F29, F30, F31, F36, F38, F41, F44, F46, F47, F49, F50, F54, F56, F57, F59, F61, F62, F74, F75, F76, F78, F79, F80, F82, F83, F84, F87, F93, F94, F96, F97, F100, F101, F110, F111 = **41**
- Skip: F58, F63, F77, F85, F95, F103, F104, F105, F106, F107 = **10**
- Total: **112**

Open questions: helper flag `flow-fetch` (enabled-only payload, purpose unknown) was not resolved in the time available. Flags `canto-launch-modal` and `linkedin-apps` are unidentified product surfaces.
