# Wispr Flow 1.6.1174: app architecture (reverse-engineered for shepetal)

Scope: process model, Electron to Swift helper IPC (HelperAPI), local storage, settings, onboarding and permissions, notes and history, stats, feature flags, updater, telemetry. Behavior only. No Wispr code, prompts or assets are copied. Evidence is given as path plus symbol.

Sources:
- `/Users/sorcecoder/shepetal-re/asar/package.json` (scripts and dependencies)
- `/Users/sorcecoder/shepetal-re/asar/.webpack/main/index.js` (main bundle, about 9.9 MB)
- `/Users/sorcecoder/shepetal-re/asar/.webpack/renderer/*/` (9 renderer entry points)
- `~/Library/Application Support/Wispr Flow/flow.sqlite` (schema only, via `sqlite3 -readonly .schema`) and `config.json` (key names and types only, no values beyond booleans and enums)
- `/Applications/Wispr Flow.app/Contents/Resources/swift-helper-app-dist/Wispr Flow.app/Contents/Info.plist`
- `/Users/sorcecoder/shepetal-agent/re/helper-disasm.txt` (grep only)
- REA `npx -y rea-agents@latest analyze-javascript-application /Users/sorcecoder/shepetal-re/asar --artifact-format directory` produced `/Users/sorcecoder/shepetal-re/app/rea-analyze.json` (208 MB, about 10 min). It parsed 165 of 183 files and found 2293 modules, 9 renderers, 36 context-bridge APIs, 207 IPC operations (90 with dynamic channel names) and 79 endpoints. Limitation: the REA worker ran out of heap on `.webpack/main/index.js` (and on 903.js and both Opus workers), so the main-process findings below come from direct grep of index.js. REA does confirm that the only literal renderer channels are `log` and `zubridge:*`. Its endpoints are mostly from `.webpack/main/311.js`, a lazily loaded bundled OpenAI SDK + Braintrust client (`/chat/completions`, `/audio/transcriptions`, `/realtime/transcription_sessions`, `btql`, `function/invoke`), which suggests an LLM provider and eval path inside the app. `extensionBootstrap.js` contributes 16 more.

## 1. Process model

| Process | What it is | Evidence |
|---|---|---|
| Electron main | Node process: state, DB, network, ASR streaming, hotkey routing, window management | `package.json` `main: .webpack/main`; Electron Forge + webpack plugin |
| Renderers (9) | React windows: `hub` (main app), `status` (Flow Bar pill), `overlay`, `contextMenu`, `scratchpad`, `meeting_recorder`, `feature_tour`, `accessibility_drop` (drag-to-grant guidance), `meeting_ax_inspector` (internal debug) | `.webpack/renderer/<name>/index.html` + `preload.js` |
| Native helper (macOS) | Swift app `com.electron.wispr-flow.accessibility-mac-app`, `LSUIElement=1`, min macOS 12. Does keyboard/mouse taps, AX reading, paste, sounds, haptics, BLE ring, meeting detection | helper `Info.plist`; launcher in `index.js` module `20844` |
| Native helper (Windows) | C# app `Wispr Flow Helper.exe`, generated from the same schema | `package.json` script `generate-helper-csharp-types` |
| Workers | `opusEncoder.worker.js`, `incrementalOpusEncoder.worker.js` (opusscript WASM), `profilingWorker.js` | `.webpack/main/` |
| Extension host | `extensionBootstrap.js` + `agentToolBridge.js`. Spawns external coding-agent CLIs and passes newline-delimited JSON user messages on stdin; bridges tools | `agentToolBridge.js` `sendMessage`/`setupToolBridge`; flag `extension-system` |
| Native addons | two `.node` files; `@wispr/panel-activation` (non-activating panel windows); `sqlite3` | `.webpack/main/*.node`, `package.json` deps |

Renderer to main: each preload exposes a generic `window.electron` (ipc invoke/send/on, a guarded `shell.openExternal`, clipboard, platform info including a mac system-audio capability probe that returns process_tap on macOS 14.4 and later and screen_capture_kit on 13 to 14.3, paths) plus `window.zubridge`. App state is a zustand store in main and is mirrored into every window with `@zubridge/electron` (channels `zubridge:dispatch`, `zubridge:get-state`, `zubridge:state-update-ack`, and so on). That means there is no big per-feature channel list: renderers dispatch actions to the main store. Evidence: `hub/preload.js` `exposeInMainWorld("electron"|"zubridge")`. Main also registers about 150 `e2e:*` handlers for Playwright tests (for example `e2e:meetingInjectMicPcm`, `e2e:scratchpadOpen`), which show which subsystems exist.

shepetal takeaway: one Rust or Swift core process plus a thin UI process is enough. A single shared store pushed to every window (the zubridge pattern) is worth copying. Use Tauri events, or a plain JSON channel.

## 2. Electron to helper IPC (HelperAPI)

Transport (`index.js`, launcher module `8460`, class with `pushData`/`writeMessage`):
- The helper is spawned with `stdio: [pipe, pipe, pipe, pipe]`. Electron writes to the helper on stdin. The helper writes IPC to Electron on fd 3. Helper stdout is logged as "non-IPC" and stderr is filtered for benign system noise.
- Framing: UTF-8 JSON messages separated by `|`, with `+` as the escape char: `+` becomes `+1` and `|` becomes `+2` (`escapeMessage`/`unescapeMessage`). There is an optional async write queue (flag `is-async-helper-write-queue-enabled`) and a per-message size cap (returns `too_long`).
- Envelope: `{HelperAPIRequest: {...}}` or `{HelperAPIResponse: {...}}`. The message type is the single non-metadata key. Metadata keys are `uuid` (request/response correlation via `registerResolver`), `sentryTrace` and `sentryBaggage` (distributed tracing over IPC).
- Lifecycle: spawn, `IsReady` handshake (timeout class `spawn_handshake_timeout`), relaunch with backoff and a mutex. The relaunch count resets after the helper has run 1 minute. `HelperAppShutdown` on quit. Flags `kill-orphan` and `kill-detached-helper` clean up stale helpers.
- Codegen: one JSON Schema (`src/api/helper/schema.json`) is bundled and turned by quicktype into TS, Swift (`IPC/Models.swift`) and C# models (`package.json` scripts `bundle-helper-schema`, `generate-helper-*`). shepetal should copy this idea: one schema with generated bindings per platform.

Both directions use `HelperAPIRequest` (event-style messages flow both ways). `HelperAPIResponse` carries replies to `Get*` requests. Members extracted from the quicktype typemap in `index.js` (search `HelperAPI:L([`):

### 2.1 HelperAPIRequest (102 members), grouped

| Group | Messages | Purpose (paraphrased) |
|---|---|---|
| Lifecycle | `IsReady`, `HelperAppShutdown`, `StartAllIntervals`, `StopAllIntervals`, `UpdateFeatureFlags`, `UpdateShortcuts`, `CheckStaleKeys`, `TapRecoveryEvent`, `SecureInputStatus` | readiness, polling control, pushing flags and hotkey map to the helper, stuck-modifier detection, event-tap recovery, Secure Input detection (blocks hotkeys) |
| Hotkeys / input | `KeypressEvent`, `InputEvent` (kinds keyDown, mouseDown, mouseUp, scroll; modifiers command, control, function, option, shift), `SetInputEventCapture`, `SimulateKeyPress` | the helper's CGEventTap reports keys and mouse; Electron decides PTT, hands-free and so on |
| Dictation | `DictationStart`, `DictationStop`, `RecordingStarted`, `PlayDictationStartSound`, `PlayDictationStopSound`, `AudioCodecChanged`, `AudioInterruptionEvent` (began/ended), `IsMediaPlayingUpdate`, `FireHaptic` (bubbleHover/bubbleUnhover) | start and stop cues, sounds, pausing media while dictating, haptics |
| Context capture | `AppContextUpdate`, `AppContextHTML`, `AppInfoUpdate`, `CursorContextUpdate`, `AccessibilityTreeHTML`, `SetAccessibilityTreeCapture`, `GetTextBoxInfo`/`TextBoxInfo`, `GetSelectedTextViaCopy` (copy mode `slack`), `StoreFocusedAppAndElement`, `FocusStoredAppAndElement`, `SuggestSelectTextbox`, `ClipboardChanged`, `DockInfoUpdate`, `HardwareInfoUpdate`, `SetFocusChangeDetectorState` | the active app, URL, focused textbox contents, AX tree as HTML, and text around the cursor, all used as LLM context; links copied to the clipboard; restoring focus before paste |
| Insertion | `PasteText`, `CancelPaste`, `PasteOutcome`, `PasteBlocked`, `PasteAnalytics`, `DictatedTextVerification` (verdicts verified, verified_before_after, not_found, skipped), `GetDictatedTextPosition`, `UpdateEditedText` (with a keystroke trace), `ActivateRunningApp` | paste through the clipboard, then verify the text landed, then watch for later user edits (feeds auto-learned dictionary words) |
| Accessibility UX | `RequestAccessibilityPermission`, `GetAccessibilityStatus`, `StartAccessibilityServices`, `SetAccessibilityGuidance`, `GetSystemSettingsWindowBounds` | permission prompting and the drag-the-app-into-System-Settings overlay |
| Floating web panel | `ShowFloatingWebPanel`, `HideFloatingWebPanel`, `EvaluateFloatingWebPanelJS`, `FloatingWebPanelEvent` (panel levels floating, statusBar, screenSaver) | the native panel that hosts web UI above other apps |
| Focus mode | `SetFocusMode`, `FocusModeBlocked` (type app/url) | blocks configured apps and URLs |
| BLE ring | `BleStartPairing`, `BlePairResult`, `BleSetPairedDevice`, `BLEConnectionState`, `BLEControl`, `BLEAudioData` | a Bluetooth LE mic ring for hands-free dictation (audio arrives over IPC) |
| Meetings | `GetMicrophoneHolders`, `SetMicrophoneHoldersMonitor`, `MicrophoneHoldersChanged`, `HolderClickObserved`, `GetMeetingTabScan`, `SetTabStripMonitor`, `TabStripRowChanged`, `GetNativeCallSnapshot`, `NativeCallSnapshotCompleted`, `GetConferenceEndState`, `BrowserLeaveProof`, `SetNativeDropWitness`, `NativeDropWitnessReport`, `MeetingWindowBindReport`, `MeetingSpeakerSourceReport`, `MeetingSpeakerChange`, `StartSpeakerPolling`, `StopSpeakerPolling`, `GoogleMeetAudioDeviceChanged`, `GoogleMeetMicrophoneMuteChanged`, `TeamsMeetingAudioChanged`, `ZoomMeetingAudioChanged`, `PositionBrowserWindow` (split/awaitWindow/resplitIfMoved), `PostConsentChatMessage`, `CancelConsentChatMessage`, `ConsentChatMessageOutcome`, `GetSystemAudioStatus`, `RequestSystemAudioPermission` | detects calls (platforms google_meet, slack, teams, zoom), reads the active speaker from AX, detects "leave call" clicks in 12 browsers (arc, atlas, brave, chrome, comet, dia, edge, firefox, opera, safari, vivaldi, zen), posts a recording-consent chat message, and splits the screen next to the meeting window |
| Misc | `GetDeviceInfo`, `GetHardwareInfo`, `GetRunningApps`, `GetActiveAppInfo`, `GetAppInfo`, `GetMicrophonePrivacyStatus`, `TrackAnalyticsEvent` | device and app info; the helper forwards analytics through Electron |

### 2.2 HelperAPIResponse (28 members)
`ACK`, `HelperAPIError`, `HelperLaunchTiming`, `AccessibilityStatus`, `ActiveAppInfo`, `AppInfo`, `RunningApps`, `DeviceInfo`, `HardwareInfo`, `TextBoxInfo`, `SelectedTextViaCopy`, `DictatedTextPosition`, `StaleKeysResponse`, `TapState`, `SystemAudioStatus`, `SystemAudioPromptResult` (alreadyDetermined, alreadyInFlight, triggered, unavailable), `SystemSettingsWindowBounds`, `MicrophonePrivacyStatus`, `MicrophoneHolders`, `MicrophoneHoldersMonitorStatus`, `MeetingTabScan`, `TabStripMonitorStatus`, `NativeCallSnapshot`, `NativeDropWitnessStatus`, `ConferenceEndState`, `BrowserLeaveProofStatus`, `BrowserWindowPositioned`, `uuid`.

### 2.3 Helper-side feature flags (pushed by `UpdateFeatureFlags`)
`BleMicRing`, `CodingCLIDetection` (detects aider, claude, cline, codex, cursor-agent, gemini, opencode, qwen running in a terminal), `CursorIntegration`, `DisableClipboardRestore`, `ExtensionSystem`, `FailedPasteNotification`, `FlowFetch`, `FocusChangeDetectorAppChange`/`Enabled`, `IsAudioInterruptionMonitoringEnabled`, `KillDetachedHelper`, `KillOrphan`, `MultiKeybindService`, `NotetakerAirpodsAudioDiagnostics`, `NotetakerAudioSwitching`, `RemoteViewerPaste`, `ShiftInsert`, `SkipURLSearch`, `TapWatchdog`, `WindowsKeyUpSimulation`, `WindowsShortcutMaskingV2`.

Helper macOS APIs seen in the disasm (grep counts): `AXIsProcessTrusted` (18), `CGEventTapCreate` (5), `CGEventPost` (22), `NSPasteboard` (21), `NSWorkspace` (15), `CGPreflightListenEventAccess` (1), `CBCentralManager` (2).

shepetal minimal helper surface (P0): IsReady, UpdateShortcuts, KeypressEvent, DictationStart/Stop, AppContextUpdate, GetTextBoxInfo, PasteText, PasteOutcome, Get/RequestAccessibilityStatus, SecureInputStatus. Everything else is P1 or P2.

## 3. Local storage

### 3.1 Files under `~/Library/Application Support/Wispr Flow/`
`flow.sqlite` (+ WAL), `config.json` (electron-store prefs), `feature-flags-cache.json` (flag `desktop-feature-flags-disk-cache`), `session.json` (auth session), `meetings/` (meeting audio), `backups/`, `avatars/`, `sentry/`, `gpu-guard.json` (GPU crash guard), plus Chromium profile dirs. `package.json` script `reset-profile` deletes `flow.sqlite` and resets permissions.

### 3.2 flow.sqlite (Sequelize + umzug migrations; `SequelizeMeta` tracks applied migrations)

| Table | Holds | Notes for shepetal |
|---|---|---|
| `History` | one row per dictation: `asrText`, `formattedText`, `editedText`/`editedTextUnbounded` (what the user changed afterwards), `pastedText`, `audio` + `builtInAudio` BLOBs, `opusChunks`, `screenshot` BLOB, `axText`/`axHTML`/`textboxContents`/`additionalContext` (captured context), `app`, `url`, `language`/`detectedLanguage`, `duration`, `speechDuration`, `numWords`, `e2eLatency`, `clientNetworkLatency`, primary vs fallback ASR and formatter outputs with divergence scores, `transcriptCommand`, `personalizationStyleSettings`, `toneMatchedText`, `numDictionaryReplacements`, `numWordsCorrected`, `feedback`, `isArchived`, `needsUploading`, `shareType` | P0: keep `asrText`, `formattedText`, `editedText`, `app`, `duration`, `numWords`, `timestamp`, optional audio. Index `idx_history_per_app_stats` drives per-app stats |
| `Dictionary` | `phrase`, `replacement`, `replacementHtml`, `isSnippet`, `isStarred`, `manualEntry`, `source`/`observedSource` (auto-learned), `frequencyUsed`, `lastUsed`, `teamDictionaryId` | one table covers vocabulary, replacements and snippets |
| `Notes`, `NoteVersions`, `NoteImages` | scratchpad notes (title, content, `searchableContent`, pinned, finalized), version history with `transformPrompt`, embedded images (S3 upload columns) | local only for shepetal |
| `Polish` | selection rewrites: input and output text, word counts, `instruction`, `promptName`, `shortcutKey`, `polishUndone`, provider, latency | "Polish" = rewrite selected text |
| `InstructHistory`, `InstructChatSession` | command-mode and "instruct" runs: classifier route, tool calls, session turns, feedback | voice commands / agent mode |
| `FlowLensHistory` | chat turns for the "lens" shortcut (ask about screen): role, content, screenshot, AX context, tools | P2 |
| `UserContext` | `writingSamples`, `polishPrompts` | style personalization input |
| `UserVoicePreferences` | free-text preference + filter | "my voice" rules |
| `Meetings`, `MeetingVersions`, `Folders`, `FolderMeetings`, `SharedNotes`, `TranscriptCorrections`, `Todos`, `Automations`, `CalendarEvents`, `NotetakerChats`, `NotetakerChatMessages`, `NotetakerChatAgentStates`, `GranolaImportRun`, `GranolaTranscriptQueue` | the notetaker: meetings with notes, summary, speaker map, refine pipeline state, share slug, retention; calendar mirror with pre-read; per-meeting todos; automations; meeting Q&A chats; Granola import | covered in depth in `meetings.md` |
| `Links` | URLs the user copied, with title enrichment | backs link insertion ("paste that link") |
| `RemoteNotifications` | server-pushed in-app notifications | skip |
| `UsageOutbox` | queued usage counts for billing (flag `never-store-usage-outbox`) | skip (no quota) |

### 3.3 `config.json` top level
`prefs` (settings + caches), `notifications` (per-notification-type state, about 200 types), `nudge`, `activationCron`, `voiceProfile`, `calendarSync`, `syncCoordinator`, `syncSocketClient`, `degradedNetwork`, `helperLaunch`, `autodetectReminder*`.

## 4. Settings inventory (`config.json` `prefs.user`, 201 keys; user-facing ones)

| Area | Keys |
|---|---|
| General / app | `openAtLogin`, `hideAppInDock`, `theme` (light/dark, flag `dark-mode`), `uiLocale`, `statusDockEdge` (Flow Bar edge), `hideFlowBarPermanently`, `enableSounds`, `selectedSoundFolder`, `notificationSettings` (tipsAndSuggestions, featureHighlights, milestonesAndProgress, teamUpdates, teamLeaderboardUpdates) |
| Shortcuts | `shortcuts` map of keycode combo to action. Actions seen: `ptt` (Fn), `popo` (hands-free toggle, Fn+Space), `dismiss` (Esc), `lens`, `paste_last_text`, `copy_last_text`, `polish`, `polish_prompt_1`, `view_diff`, `open_meeting_recorder`; also `modifierShortcut`, `lastSetScratchpadShortcut`, `stashed*Shortcuts`, `handsFreeShortcutRemoved` |
| Audio | `overrideAudioDeviceId`, `rankedAudioDevices`, `shouldMuteAudio`, `shouldPauseAudio` (mute or pause media while dictating), `streamAudio`, `jabraWearDetectionEnabled`, `internal.pairedBLEDeviceId` |
| Languages | `selectedLanguages`, `usedLanguages`, `effectiveLanguages` (multi-language auto-detect; the language picker is being retired) |
| Formatting / AI | `aiFormatting`, `defaultTranscriptionFormat` (for example "Apply AI formatting"), `appTranscriptionFormats` (per-app override), `autoCleanup.level` (for example light), `personalizationStyles` (work, email, personal, other: tone per app category), `styleDetectionEnabled`, `userVoices`, `useAxContext`, `shouldOCRScreenCapture`, `ideFileTagging`, `cursorIdeIntegration`, `emailAutoSignature` + `emailSignatureOption`, `pressEnterCommandEnabled` ("press enter" voice command), `commandModeEnabled`, `stackedMessagesEnabled` |
| Dictionary | `shouldAutoLearnWords`, `dictionarySort` |
| Polish | `polishEnabled`, `polishAutoPaste`, `polishInstructions` (default + custom prompts), `autoPolishAfterDictation` |
| Scratchpad | `scratchpadInFlowBar`, `notesViewType`, `defaultNoteVisibility`, `internal.scratchpad*` |
| Focus mode | `focusModeEnabled`, `focusModeBlockedApps`, `focusModeBlockedUrls` |
| Privacy / data | `localDataPolicy` (store_normally, delete_after_24h, never_store), `cloudSync`, `shareUsageData`, `internalDataSharingEnabled`, `instructInternalDataSharingEnabled`, `isGlobalProfileSharingEnabled` |
| Notetaker | about 60 `notetaker*` keys: auto-detect meetings, calendar notifications and timing, consent chat message, auto-share notes, auto-end, auto-start, max recording length (for example 3hr), live transcript, attribute speaker names, notepad on start, split-screen join, open window on record, menu-bar meeting, triple-tap shortcut, transcript retention, `hideMeetingRecorderInScreenShare`, org insights default |
| Notifications | `processingDelayNotificationEnabled`, `clickableBubbleSnoozeUntil` |
| Account / plan (skip) | `subscription`, `enterprise`, `registeredDevices`, `skipDefaultTrial`, `bonusEndsAt`, referral and trial keys |
| Onboarding state | `onboardingCompleted`, `pagesCompleted`, `postOnboardingStep`, `personalizationOnboardingCompleted`, `polishOnboardingCompleted`, `tutorials` (sentMessages, sentEmails, usedHandsfree, usedWhisperMode), `userInformation` (role, industry, writingNeeds, topUseCases, traits), many coachmark booleans |
| Internal toggles | `internal.isToneMatchEnabled`, `isHapticsEnabled`, `shouldSaveAxText`, `isCandidateAsrEnabled`, `isAutoInstructEnabled`, `instructPasteOnEmptyContext` |

## 5. Onboarding and permissions

Onboarding page ids (enum in `index.js`): login, welcome-basic/team, about-yourself, spend-time-typing, work-environment, social-proof, testimonials, introduction, privacy, **permissions**, **microphone-test**, **language**, **shortcut**, tiy-intro / try-it-yourself (variants Slack, Gmail, Notion, WhatsApp), time-savings pages, writing-needs, use-cases, personalize-* (personal, work, email, other), team and referral pages, flow-pro, trial pages, voice-profile, product-intent, meeting pages (how-do-you-record-meetings, connect-calendar, connect-apps), polish. For shepetal the essential path is: permissions, then mic test, then language, then shortcut, then try it yourself.

Permissions (`index.js`, `$.$` enum and `Ae` deep-link switch; `prefs.permissions` stores `{name, clicked, granted}`):
- **Microphone**: `systemPreferences.getMediaAccessStatus("microphone")` / `askForMediaAccess("microphone")`; deep link `Privacy_Microphone`. Required.
- **Accessibility**: checked by the helper (`AXIsProcessTrusted`), requested with `RequestAccessibilityPermission`, deep link `Privacy_Accessibility`, plus the `accessibility_drop` drag-guidance window (flag `accessibility-drag-guidance`). Required for the event tap, AX context and paste.
- **Screen capture**: `getMediaAccessStatus("screen")`, deep link `Privacy_ScreenCapture`. Optional (screenshot context and OCR).
- **System audio** (meetings): `GetSystemAudioStatus`/`RequestSystemAudioPermission`, using a Core Audio process tap on macOS 14.4 and later or ScreenCaptureKit on 13 to 14.3; `NSAudioCaptureUsageDescription`. P1.
- **Bluetooth**: `NSBluetoothAlwaysUsageDescription` (BLE ring). P2.
- **Input Monitoring**: no separate onboarding step was found. The helper calls `CGPreflightListenEventAccess` once, and the CGEventTap works under the Accessibility trust. `SecureInputStatus` warns when Secure Input blocks hotkeys (notification `SecureInputBlockingShortcuts`).
- Revocation notifications: `MicrophonePermissionRevoked`, `AccessibilityPermissionRevoked`.
- Windows: `ms-settings:privacy-microphone`.

## 6. History, notes, scratchpad
- History lives in the hub: a per-dictation list with raw vs formatted text, retry, copy, "undo AI" (`hasRevertedAI`), feedback, archive, audio playback. Retention follows `localDataPolicy`.
- Scratchpad = notes window (`scratchpad` renderer, Lexical editor) with tabs, pinning, versioning (`NoteVersions`), images, AI transforms on a note (`transformPrompt`), and optional cloud sync and share (`SharedNotes`, `notes.wisprflow.ai`).
- Polish / transforms: rewrite selected text from a hotkey (`Polish` table, `view_diff` shortcut shows a diff using `diff-match-patch`).
- Copy last / paste last transcript shortcuts.

## 7. Stats and gamification
- Per-app word stats (`idx_history_per_app_stats`), WPM and time-saved comparisons (onboarding pages time-savings-speed-comparison; the hub has many `wpm` references), daily streak (flag `daily-streak`), insights heatmap (`cache.lastInsightsHeatmapReconcileAt`), "voice profile" persona card (`config.json` `voiceProfile`: peak time, top app, most-used word, catch phrase, word-count milestone, generated server-side), team leaderboard (flag `pro-team-leaderboard`), milestones and confetti.
- shepetal: compute WPM = numWords / duration, streaks and per-app counts locally with SQL over `History`. A team leaderboard reads stats files from a folder the team shares (inventory F63).

## 8. Feature flags
- Provider: PostHog feature flags (`posthog-node`, host `us.i.posthog.com` and a PostHog proxy on Wispr's own domain), cached to `feature-flags-cache.json`, and pushed to the helper via `UpdateFeatureFlags`. The enum holds about 230 flags (for example `stream-text`, `use-opus`, `use-msgpack`, `grpc-http-race`, `use-candidate-asr`, `auto-cleanup-v0`, `style-detection`, `scratchpad`, `meeting-recorder`, `cloud-sync`, `instruct-mode-experiment`, `ble-mic-ring`, `flow-fetch`, `extension-system`, `coding-cli-detection`, `dark-mode`, `localization-framework`), plus A/B variants (control/test, arm_a/b/c and so on). Pricing and trial experiments make up a large share.
- shepetal: no remote flags. Use compile-time features and a local `settings.toml`.

## 9. Auto-updater
- Electron `autoUpdater` (Squirrel.Mac) with `setFeedURL` pointing at `https://dl.wisprflow.com/<channel>/<platform>/<arch>` (`RELEASES.json` on Windows), channels `wispr-flow` and `wispr-flow-override`. An update is applied only when the last push-to-talk was more than 20 minutes ago (`Q=12e5` ms compared with `minutesSinceLastPTT`), and not while a dictation is in progress. Flag `defer-updates-while-active` adds more deferral, and `prefs.updateRetry` tracks errors. There is also a managed-config (MDM) update policy (`updateRetry.lastManagedConfig`). Builds are published to S3 (`@electron-forge/publisher-s3`), and makers produce DMG, ZIP, Squirrel, WiX, deb and rpm (so a Linux build exists in the toolchain).
- shepetal: GitHub Releases plus Sparkle (mac) or the Tauri updater, opt-in, and never mid-dictation.

## 10. Telemetry and network (what shepetal must NOT do)
- Analytics: PostHog (`us.i.posthog.com`, `eu.i.posthog.com` and a proxy on Wispr's own domain), Segment (`api.segment.io`, `cdn.segment.com`), and Datadog browser logs (`logs.browser-intake-datadoghq.com`). The analytics event enum in `index.js` has 1065 event names. The biggest groups are onboarding_* (160), notetaker_* (131), meeting_* (37), insights_* (30) and flow_* (30); others include paste_text_outcome, paywall_* and mcp_tool_called. The helper forwards its own events (`TrackAnalyticsEvent`, `PasteAnalytics`).
- Errors and tracing: Sentry (`@sentry/electron`, traces propagated into the helper through `sentryTrace`/`sentryBaggage`), event-loop-blocked logs (`blocked-at`), CPU profiling worker (flag `cpu-profiling`).
- Data upload: `needsUploading` columns on History, Polish, InstructHistory, FlowLensHistory and UserVoicePreferences. Dictation audio, screenshots and AX context are stored and uploaded unless the data-sharing settings and `localDataPolicy` say otherwise.
- Backends: Wispr's API hosts (a main one and a US-east one), a cloud host, an older API host used by `AriaWebClient`, gRPC streaming and a Baseten chain on Baseten, models on Modal, Supabase (auth/sync), WorkOS (enterprise SSO), sync websocket (flag `enable-sync-ws`).
- shepetal stance: zero network by default. No analytics SDK, no crash upload. Logs are local only. Any model download is explicit.

## 11. Dependency signals (package.json) mapped to shepetal choices
| Wispr dep | Role | shepetal |
|---|---|---|
| sqlite3 + sequelize + umzug | DB + migrations | SQLite + plain SQL migrations |
| electron-store | prefs | a settings file |
| @zubridge/electron + zustand | cross-window state | single store + events |
| @grpc/grpc-js, notepack.io, opusscript | stream Opus audio to cloud ASR | local whisper.cpp / Parakeet, no encoding |
| lexical, turndown, react-markdown, remark-gfm | notes editor, HTML to Markdown | any Markdown editor |
| diff-match-patch | polish diff view | same idea |
| cheerio | link title enrichment | optional |
| @gnaudio/jabra-js | Jabra headset button | P2 |
| @modelcontextprotocol/sdk | notes and meetings MCP server (`mcp-server`, `notetakerMCPVisibilityState`) | P1: local MCP server over SQLite |
| pdf-lib, jszip, csv-parse | export, dictionary import | P2 |
| posthog-node, @sentry/electron, supabase, workos | telemetry, auth | none |
| mac-ca, win-ca | system trust store | n/a |
| howler, lottie-web, canvas-confetti, hls.js | sounds, animations | minimal |
