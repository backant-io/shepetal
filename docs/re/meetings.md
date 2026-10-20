# Wispr Flow 1.6.1174: meeting notetaker (RE notes)

Scope: how Wispr Flow's "Notetaker" (Mac, launched August 2026) detects meetings, captures audio, transcribes, names speakers, summarizes and stores meetings, and what shepetal must rebuild with local models only.
Method: static reading of the bundled JS, the SQLite migrations and the Swift helper's strings/imports with grep. Nothing was launched and no Wispr server was contacted. REA was not needed: the JS is readable after a `;`-split, and the helper's class and log names were enough.
Behavior is paraphrased. No code, prompts, long strings or assets are copied.

Evidence key:
- `main` = `/Users/sorcecoder/shepetal-re/asar/.webpack/main/index.js` (Electron main bundle, minified). Offsets are byte offsets. The detection module sits at about 5.52-5.76 MB; a `;`-split dump is in `/Users/sorcecoder/shepetal-re/meetings/detect.js`.
- `enc` = `/Users/sorcecoder/shepetal-re/asar/.webpack/main/incrementalOpusEncoder.worker.js` and `opusEncoder.worker.js`.
- `helper` = `/Applications/Wispr Flow.app/Contents/Resources/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow` (class and log names from `strings`, imports from `nm -u`).
- `mig` = `/Applications/Wispr Flow.app/Contents/Resources/migrations/`. The header comments of these files explain the data model well. A digest is in `/Users/sorcecoder/shepetal-re/meetings/migration_notes.txt`.
- `web` = https://wisprflow.ai/post/wispr-flow-notetaker, https://wisprflow.ai/notetaker, https://docs.wisprflow.ai/articles/5166327995 (MCP), https://www.digitaltrends.com/computing/wispr-flow-launches-an-ai-note-taker-that-works-without-joining-calls/.

## 1. Features

| Feature | What it does | Where it runs | Evidence |
|---|---|---|---|
| Bot-free recording | Records mic and system audio on the Mac. No bot joins the call. | Local capture | web; main `[MeetingDisplayMedia]` |
| Auto-detect | Spots a call in a native app or a browser tab and shows a card to start the notetaker. Optional auto-start (off by default; the opt-in is offered at stop or after the call ends, `[AutoStartOptIn] Offered at stop`). | Local | main `MeetingAutoDetect*`, prefs `autoDetectMeetingsEnabled` (default on), `notetakerAutoStartEnabled` (default off), `[AutoStartOptIn]` |
| Auto-end | Stops the recording when the call ends, with a pre-stop banner and countdown. | Local | main `MeetingAutoStop`, `MeetingAutoEnded`, pref `notetakerAutoEndEnabled` (default on) |
| Manual start | Hub button, menu bar ("join meeting", "next meeting", "recent meetings"), a triple-tap shortcut, calendar reminder. | Local | `menus_join_meeting`, `notetakerTripleTapShortcutEnabled`, `notetakerMenuBarMeetingEnabled` |
| Live transcript | Streaming transcript during the call, with optional translation. | Cloud | main `api/v1/meetings/transcribe?source=&translation_target=` |
| Final transcript | After the call the full recording is processed again with more context. | Cloud (Soniox) | mig `submit-accepted-at` ("Soniox webhook"), web |
| Speaker names | Names from the calendar invite and from the meeting app's active-speaker UI. Users can rename, split and reassign speakers. | Local observation, cloud attribution | helper `MeetingSpeakerPoller`, mig `speaker-map`, main `transcript-speakers/split` |
| Summary | Markdown summary by topic with dates, decisions, next steps and owners. User-editable. | Cloud LLM | web; mig `notes-summary` |
| Notepad | User's own notes during the call (Lexical editor JSON), opened at start. | Local + sync | mig `notes-summary`, pref `notetakerNotepadOnStart` |
| Pre-meeting brief | Brief built from notes, calendar, connected apps and the web, with sources. | Cloud | web; `CalendarEvents.prereadSummary` |
| Notetaker chat | Ask questions about one meeting or the whole history, answers link to the moment. | Cloud LLM | mig `create-notetaker-chat-tables`, `/api/v1/notetaker-chats/{id}/messages` |
| Consent notice | Optionally posts a chat message into the meeting app's chat saying the notetaker is on. Skipped when a colleague's Flow already posted it for that event. | Local AX automation | helper `ConsentChatMessage: ...`, main `consentChatMessageEnabled`, `sendConsentNoticeUnlessPeerPosted` |
| Calendar notice | Optional notice tied to the calendar event (default Off). | Cloud | pref `notetakerCalendarNotice`, `[CalendarNotice]` |
| Folders, sharing | Folders with rules, share links (anyone with link / domain / invited only), auto-share after the meeting (default Off). | Cloud | mig `folder-meetings`, `share-columns`; prefs `notetakerAutoShareNotes` |
| MCP export | Read-only remote MCP connector for Claude/ChatGPT: meeting notes, summaries, briefs (not dictation history). Works next to Granola/Otter/Fireflies connectors. | Cloud | web (docs article) |
| Import | Granola import. | Cloud | mig `import-source`, flag `granola-import` |
| Retention | Transcript retention: never, 1, 7, 30, 90, 180, 365 days. Org admins can set it. | Server deletes, client purges | pref `notetakerTranscriptRetention` default never; mig `transcript-deleted-at` |
| Platforms | Mac first; Windows code paths exist (exe/MSIX maps, `audio: 'loopback'`, flags `notetaker-windows`, `meeting-recorder-windows-acting`); Linux build skips system audio. English-focused (`NotetakerUnsupportedLanguageDetected`). | - | main module `20775`, `[MeetingDisplayMedia]`, web |
| Limits | Max recording length (default 2 h, with a warning before the cap), long-meeting check-in, weekly quota on the free plan. | Local | pref `notetakerMaxRecordingLength` = 2 h (72e5 ms), `DismissNotetakerWeeklyLimit` |

## 2. Detection algorithm

### 2.1 Platform catalogue (main module `20775`, offset about 2.765 MB)

A table maps bundle ids (Mac), exe names (Windows) and MSIX ids to a platform key. Three groups:

- Native meeting apps, trusted alone: FaceTime (`com.apple.facetime`, and `com.apple.avconferenced` for FaceTime audio), Webex, Dialpad Meetings, Gather, Lark, Microsoft Teams (`com.microsoft.teams`, `teams2`, `teams2.modulehost`), VooV/Tencent Meeting, Zoom (`us.zoom.xos`).
- Browsers, which need a meeting tab: Arc, ChatGPT Atlas, Brave, Chrome (stable/beta/dev/canary, Chromium), Comet, Dia, Edge, Firefox, Opera, Safari (the `com.apple.webkit.gpu` process counts as Safari), Vivaldi, Zen. Helper processes (`.helper`) map to the parent.
- Comms apps that count only with extra proof: Slack (huddle), Discord, WhatsApp, Aircall, Dialpad, ClickUp, Tuple.

Eligibility (function `h` in that module): a native meeting app is eligible; a browser is eligible only when its front tab's conference service is Google Meet, Teams or Zoom web; Slack is eligible only when a huddle was seen. Hosts: zoom.us, zoomgov.com, meet.google.com, teams.microsoft.com, teams.live.com, webex.com, slack.com, discord.com.

### 2.2 Signals

1. Mic holders from Core Audio (the primary trigger). helper `MicrophoneHoldersMonitor`, `SystemMicrophoneHoldersCoreAudioAdapter`. It reads the Core Audio process object list, keeps the processes that run input (and separately output: `outputHolders`), and resolves each to a bundle id. It uses property listeners (`AudioObjectAddPropertyListenerBlock`) and re-registers when coreaudiod restarts. It pushes `microphoneHoldersChanged` with `holders` and `browserHolders`. A process with no bundle id counts as third-party; if not every process resolves, the last state is kept. Main also polls (`Mic signal poll`, "tightening mic polls" once the far end goes quiet).
2. Accessibility tree of the meeting app. helper `MeetingAXTreeReading`, `LiveMeetingAXTree`, `isInCallAnchor`. States `pre_meeting` (for example a Zoom waiting-room text), `in_meeting`, `meeting_window`. Signals `ax_in_call`, `ax_in_call_meet`, `ax_end_state` (the UI shows the call ended), `ax_unreadable`. A "conference window monitor" watches the call window; its removal promotes an end to high confidence. A click on Leave is proof of end (`Leave-click proof`).
3. Browser tab strip via AX. helper `MeetingTabScanner` (`getMeetingTabScan`). Per tab: title digest, Chrome's camera/microphone "recording" marker in the title, a Meet prefix plus meeting code (3-4-3 letters), a Teams title suffix, near-miss counts. Main strips browser decorations from titles before matching. The tab URL from the app-context tracker (`persistentAppContext.lastAppURL`) gives conference service and code when available.
4. Calendar (Google, Microsoft behind flag `notetaker-microsoft-calendar`). Events within 5 min (`calendarProximityMs` 3e5) correlate. A native Zoom call is matched to an event by time window; if several Zoom events fit, nothing is attributed. Signals `calendar_event`, `calendar_join`, `calendar_in_window`, `calendar_reminder`, `calendar_overrun`.
5. Network evidence per holder: UDP/TCP socket counts (`udpTotal`, `udpConnected`, `udpZoomMedia`, `udpStun`, `udpGoogleMedia`, `udp443`, `tcpEstablished`, `tcp443`, `threads`). Used as corroboration and diagnostics.
6. Speech activity of the live transcript: while the transcript is still producing text, stops are suppressed.

### 2.3 Start: states and thresholds

- A detection is a notice `{signal, platform, holderBundleIds, matchType}`.
- Gate (evaluator `U` in the detect module): flag `meeting-recorder` on, `autoDetectMeetingsEnabled` on, platform eligible, no recording active or stopping, onboarding done, notetaker not blocked by the org, mic and system-audio permission, cloud sync available, user did not decline this call.
- Holdoffs: 10 s after wake (`wakeHoldoffMs`), 10 s after a coreaudiod restart, 10 s after the helper is ready, a startup window, a flap cooldown, and while the mic is yielded to dictation.
- Grace: 5 s (`defaultGraceMs`). "Same meeting returned" cancels it.
- Card: `Prompt fired`; it auto-dismisses after 20 s (`dismissAfterMs`). A late calendar match upgrades the card (`MeetingAutoDetectPromptUpgraded`) or, if the recorder already runs, just tracks it for auto-stop with no card. Debounce fallback 15 s, backstop 30 s, tab absence confirmed after 1.5 s.
- Back-to-back: if the mic returns with a different conference frontmost, the app offers to switch recordings (`Conference switch — offering the switch`) and ends the old one.
- Ignored cards lead to an opt-out prompt and finally auto-disable (`MeetingNoticeOptOutPrompt`, `MeetingNoticeIgnoredOptOutPrompt`, `MeetingNoticeAutoDisabled`), with a re-enable prompt later (flag `re-enable-detection-prompt`).

### 2.4 End detection

Release kinds: `trusted_native_release` (native app let go of the mic), `zoom_web`, `scan_gone` (tab gone), `uncorroborated_browser_drop`, `conference_switch`. Then (config object near the end of the detect dump):

- No auto-stop in the first 15 s (`minSessionAgeMs`).
- Bound session (holder known and released): 3 s of silence (`boundSilenceMs`); speech counts as fresh for 5 s.
- Unbound session (no holder proof): 30 s of silence (`unboundSilenceMs`), halved within 5 min of the scheduled end.
- Sign-off phrases at the end of the transcript (a short list of English goodbyes) count as end evidence.
- Fused windows of 4 s / 5 s / 5.5 s combine signals by confidence; "ultra" holders (Slack, Discord, FaceTime, WhatsApp) use a separate high-confidence window. A far-end tail of 1.2 s is kept.
- The mic coming back within 4 s is the same meeting; a device change within 10 s is not an end.
- Server-side end vote: the live-transcript socket (capability `autostop_vote_v1`) returns `autostop_vote` frames for the mic stream with four probabilities: conversation concluded, recent audio is a meeting, a break, a sign-off; plus the end time of the last final segment and the kind (final / reread / terminal). The client fuses these votes with the local signals and can send `autostop_disarm` (for example after the user clicks Keep). So the transcript-based part of the end decision is a cloud classifier; shepetal must do it with a local model or the phrase heuristic.
- Pre-stop banner with a 5 s countdown that pauses on hover. A low-confidence stop shows Keep/Stop instead of stopping. If the transcript is still active, the stop is cancelled.
- After a stop, re-stops are suppressed for 3 min, at most 2 per session. A just-stopped meeting can auto-heal (resume) into the same row. Fast User Switch finalizes at once.

### 2.5 Prompt and notice UX

- The detection card is not an OS notification. It is drawn in Wispr's own floating "status" window (the Flow bar pill morphs into a meeting card: `ArmPopoToMeetingMorph`, `FlowBarMeetingPillHovered`). Almost all notices in main's notice table use `window:"status"`; a few use the hub window.
- Meeting notices found (type and level): `SuggestNotetaker`, `MeetingAutoEnded`, `MeetingStartedByMistake`, `MeetingSummaryReady`, `MeetingRecordingFailedToStart`, `MeetingRecordingConnectionLost`, `MeetingLiveTranscriptUnavailable`, `NotetakerMicNoAudioDetected` (+ escalated), `NotetakerMicMismatch`, `NotetakerLowDiskSpace`, `NotetakerUnsupportedLanguageDetected`, `NotetakerWeeklyLimitWarning/Reached`, `NotetakerTranscriptRetentionNotice`, `MeetingNoticeOptOutPrompt`, `MeetingNoticeIgnoredOptOutPrompt`, `MeetingNoticeAutoDisabled`, `MeetingDetectionReEnablePrompt`, `NotetakerAutoStartOptInSplash`, `NotetakerAutoHideOffer`, `NotetakerScreenShareEducation`. Most notices have a show cap (`maxTimesToShow` 1-3).
- A short recording can be discarded (`DiscardShortMeeting`), and a started-by-mistake card offers to throw it away.
- Screen share: the recorder window can hide itself while you share your screen (`hideMeetingRecorderInScreenShare`, auto-hide offer).
- Consent to participants: no bot, so the app relies on (a) the user, (b) an optional automatic chat message posted into the meeting app by AX automation (flag `notetaker-consent-chat`, pref `notetakerConsentChatEnabled` with an editable message, `GetDefaultConsentNotice`), and (c) an optional calendar notice (pref `notetakerCalendarNotice`, default Off). The chat sender waits for the user to join, brings the call window to the front, opens the chat panel (toggle or overflow menu, enlarging the window if needed), fills the composer (sets the AX value, falls back to a clipboard paste only if the clipboard can be restored), sends, and confirms the composer cleared. An org-level claim makes sure only one Flow user per calendar event posts it.
- HIPAA accounts hit a cloud-sync gate (`HipaaCloudSyncGate`), since the notetaker needs cloud sync.

## 3. Capture pipeline

- System audio comes from Chromium, not from the helper. The helper imports no `AudioHardwareCreateProcessTap` or ScreenCaptureKit symbols (checked with `nm -u` and the disassembly). Main installs `session.setDisplayMediaRequestHandler` (`[MeetingDisplayMedia]`) and the renderer calls getDisplayMedia with loopback audio. The Chromium feature switch is chosen by macOS version:
  - macOS 14.4 and later: `MacCatapSystemAudioLoopbackCapture`, a Core Audio process tap of the whole system (device id `loopbackAllDevices`).
  - macOS 13.0-14.3: `MacSckSystemAudioLoopbackOverride`, ScreenCaptureKit audio with the first screen as a dummy video source.
  - Older: unsupported. Windows: `audio: 'loopback'`. Linux: the handler is skipped ("no system loopback path"), so mic only.
- Permission: TCC `kTCCServiceAudioCapture`, preflighted and requested by the helper (`[SystemAudioPermission]`). A system-audio probe (flag `notetaker-system-audio-probe`) checks that loopback really delivers audio; e2e hooks measure peak stats and a Goertzel tone.
- Mic and system are two separate mono PCM streams, 16 kHz, 16-bit, spilled to disk per meeting (`micPcmPath`, `systemPcmPath`). The mic is yielded to dictation when the user dictates during a call (`mic_yield`).
- Encoding (`enc`, flag `notetaker-incremental-encode` / `notetaker-streaming-encode`): one Ogg Opus file `upload.ogg`, 2 channels (one per source), 16 kHz input, Opus application AUDIO, 64 kbps, 20 ms frames (320 samples), 20 packets per Ogg page. The incremental worker reads both PCM files and interleaves them while recording, so stop is fast. RMS is tracked per channel.
- Upload: presigned S3 upload (`/api/v1/meetings/{id}/upload-url`, multipart `audio-uploads/{n}` behind `notetaker-multipart`). Once the audio is confirmed in S3, the local `upload.*` is deleted. Retries come from a daily resubmit scan (`refineRetries`, `encodeRetries`).

## 4. Transcription, speakers and summary

- Offline: if the socket fails or auth is rejected, local capture continues ("preserving local capture"), the audio is uploaded later and the refine pass makes the transcript. Starting while offline asks for consent first (`start deferred for Offline recording consent`).
- Live: a WebSocket (likely one per source, since the URL takes a `source` param) to the Wispr backend (`api/v1/meetings/transcribe`, params `source`, `translation_target`), with reconnect back-off, keepalive pings and a bounded pending-audio buffer (oldest chunk dropped when full). Audio goes up as raw binary PCM frames (the client derives stream time from byte length), not Opus. It needs cloud sync on (`cloud_sync_required`). The live transcript is kept as `live.ndjson` and uploaded to S3. Entries carry `source` (mic/system), speaker, start/end in epoch ms and recording ms, and optional translation.
- Final: `/refine` returns 202, Soniox transcribes the stereo file (diarization there is inferred, not seen), a webhook writes `refined.ndjson`, then the server writes the summary. Server-owned status: awaiting_audio, transcribing, summarizing, complete, failed, abandoned. The client shows a "summary is stale" prompt when a later recording stop added audio after the last refine.
- Speaker labels: mic speakers are "Local N" and system speakers "Remote N" (a generic "Speaker N" also exists). Keeping the channels separate means the local user is never confused with remote people.
- Names: helper `MeetingSpeakerPoller` with per-app strategies (class `MeetingSpeakerZoom`; Meet attribution is named in mig `speaker-artifact-columns`) reads the active-speaker highlight via AX and writes `speakers.observations.ndjson`, which is uploaded. The server aligns those observations with the diarized turns. Calendar attendee names and photos (`participantNames`, `participants`) narrow the choice. Users can edit (`speakerMap {people, assignments}`, split a speaker, room-label edits for in-person rooms, assign a contact).
- Summary: Markdown in `Meetings.summary`, organized by topic with key dates, decisions, next steps and owners (web). Made once after the call by the refine pipeline, and regenerated by the server after a re-refine. There is no evidence of a rolling live summary in the client; "catch me up" is a chat answer. Users rate summaries (`summary-feedback`). A candidate-model summary is stored for internal A/B (`summary-model-comparison`).
- Personal dictionary from dictation is used as context (web).

## 5. Storage and search

- SQLite via Sequelize: `Meetings` (title, calendarEventExternalId, calendarOccurrenceStartAtUtc, participantNames, speakerMap, notes, summary, refineStatus, endedAt, recordedMs, shareSlug/shareVisibility, transcriptDeletedAt, upload/retry timestamps), `MeetingVersions`, `CalendarEvents` (participants, prereadSummary, RSVP, series key, conference URLs), `TranscriptCorrections` (overlay keyed by meeting, artifact revision and entry), notetaker chat tables, `FolderMeetings`, `SharedNotes`.
- Per-meeting directory under `meetingsBaseDir`: PCM spill files, `upload.ogg`, `live.ndjson`, `refined.ndjson`, `speakers.observations.ndjson`, `native-language-evidence.json`.
- Calendar events are pruned about 60 min after they end, so attendee names are copied onto the meeting at record time.
- Rejoin of the same calendar occurrence resumes the existing meeting row instead of creating a new one.
- Sync: `/meetings/sync` push/pull with per-field pending-push bits. Transcripts are not inlined; they go through presigned S3.
- Search: local, in the main process. It tokenizes the query and scores title, participant names, summary and notes, with rank, coverage and a snippet. Sources "mine" and "shared". Cross-meeting Q&A runs in the cloud chat.
- Retention: the server deletes transcripts per policy and sets `transcriptDeletedAt`; the client then purges local artifacts and the MCP refuses that meeting.

## 6. Local vs cloud

| Step | Wispr Flow |
|---|---|
| Detection (mic holders, AX, tab scan, calendar match) | Local |
| Consent chat message | Local (AX automation of the meeting app) |
| Capture and Opus encode | Local |
| Live ASR | Cloud (Wispr WebSocket) |
| Final ASR and diarization | Cloud (Soniox) |
| Speaker naming | Local observations, cloud alignment |
| Summary, brief, chat | Cloud LLM |
| Search | Local over synced metadata, cloud for chat |
| MCP | Cloud (remote connector) |
| Storage | Local SQLite cache, cloud is the source of truth; audio is deleted locally after upload |

## 7. What shepetal must build

Everything local: no audio or text leaves the device.

Common core (all platforms):
- Meeting state machine: idle, candidate (grace 5 s), prompted (card, 20 s timeout), recording, ending (pre-stop banner, 5 s countdown), stopped. Copy the thresholds as tunable config: min session 15 s, bound silence 3 s, unbound silence 30 s (halved near the scheduled end), reacquire 4 s, device change 10 s, re-stop suppression 3 min.
- Stop only on evidence plus silence; never stop while local ASR still produces text.
- Replace Wispr's cloud end vote with a local one: run a small local LLM (or a phrase list plus silence) on the last minute of the mic transcript every few seconds and output the same four scores (concluded, still a meeting, break, sign-off).
- Two channels kept separate end to end: mic = "me", system = "them". Store two 16 kHz mono files (or one stereo Ogg Opus at about 64 kbps if disk matters).
- Live ASR: local streaming model per channel (whisper.cpp streaming / Moonshine / Parakeet via sherpa-onnx). Final pass: a larger local Whisper on the full files after stop.
- Diarization: only on the system channel (sherpa-onnx or pyannote-style embeddings + clustering). Mic channel is the user.
- Names: calendar attendee names (local calendar: EventKit on Mac/iPhone, ICS/CalDAV/Evolution on Linux), plus optional active-speaker AX observations on Mac.
- Summary: local LLM (llama.cpp / Ollama / MLX) after stop, sections: overview, topics, decisions, action items with owners, dates. Optional rolling summary every few minutes.
- Storage: SQLite with FTS5 over title, attendees, transcript, summary, notes. Retention setting that deletes audio and transcripts on a timer.
- Export: a local MCP server (stdio) with read-only tools to list, search and read meetings, and Markdown export.
- Consent: show a clear recording indicator. A chat auto-post via AX is optional and Mac-only; a copyable consent line is the simple version.

Mac:
- Mic holders: Core Audio process list (`kAudioHardwarePropertyProcessObjectList`, then `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyBundleID`, PID), with property listeners. Map bundle ids to the same three platform groups.
- System audio: `AudioHardwareCreateProcessTap` with a `CATapDescription` (global tap excluding shepetal, or per-process for the holder PID) on macOS 14.4+, wrapped in a private aggregate device. ScreenCaptureKit audio as the fallback for 13.0-14.3. Needs the system-audio TCC prompt (`NSAudioCaptureUsageDescription`).
- Browser corroboration: AX read of the front window title and tab titles (Meet code pattern, "Microsoft Teams" suffix, Chrome's recording marker). URL via AppleScript for Chrome/Safari if permitted.
- End: holder release + AX window gone + silence.

Linux:
- Mic holders: `pw-dump` (or a PipeWire registry listener) for `Stream/Input/Audio` nodes; `application.process.binary`, `application.name`, `application.process.id` identify Zoom, Teams, Slack, Discord, and browsers. Use `pactl subscribe` / `pw-mon` events instead of polling where possible.
- System audio: record the default sink's monitor source (`pw-record --target <sink>.monitor` or `parec -d @DEFAULT_MONITOR@`), or link a PipeWire capture node to the call app's output stream only.
- Browser corroboration: window titles via the compositor (X11 `_NET_WM_NAME`; on Wayland only via portal or the app's own stream name, so fall back to "browser holds mic + calendar match").
- Wispr ships no Linux system capture at all, so this is a place to beat it.

iPhone:
- iOS does not allow capturing other apps' audio. Mode: in-person meetings, mic only, started manually or from a calendar reminder or Live Activity.
- Diarize the single mic channel; names from the EventKit attendees.
- Background recording with the audio background mode; local ASR (WhisperKit / Core ML) and a small local LLM for the summary, or sync the audio to the user's Mac for the heavy pass.

## 8. Open questions

- Exact Core Audio selectors. Confirmed: `'prs#'` (kAudioHardwarePropertyProcessObjectList) is loaded at disasm line 173358, next to the `[MicrophoneHolders]` log strings. The per-process selectors (is-running-input/output, bundle id, PID) were not found as immediates; they may come from a constant pool.
- How many ignored cards trigger the opt-out prompt and auto-disable; the counter constant was not located.
- Whether the live WebSocket carries both channels on one socket or one socket per source (the `source` param suggests one per source).
- Summary section names and prompt are server-side and not in the client.
- How the MCP connector is authenticated and which tools it exposes (server-side, only the help article was read).
- Whether the speaker poller covers Teams and Webex or only Zoom and Meet (strategies found: Zoom, Meet).
- Network socket counters: how the helper gets them (likely `proc_pidinfo` socket listing) and whether they gate decisions or only feed diagnostics.
