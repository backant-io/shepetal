# Wispr Flow 1.6.1174: dictation input and lifecycle

Reverse-engineering notes on how Wispr Flow starts, holds, locks, cancels and stops a dictation, how it captures audio, and how it reports state and errors. These notes describe behavior only. No code, prompts or assets were copied.

Sources (all read-only):
- Main bundle: `/Users/sorcecoder/shepetal-re/asar/.webpack/main/index.js`. Offsets are written `main@N` (character offset).
- Hub renderer (owns the microphone): `/Users/sorcecoder/shepetal-re/asar/.webpack/renderer/hub/index.js` (`hub@N`).
- Status bar renderer: `/Users/sorcecoder/shepetal-re/asar/.webpack/renderer/status/index.js` (`status@N`).
- AudioWorklet: `/Users/sorcecoder/shepetal-re/asar/.webpack/renderer/dist/recorderWorklet.js`.
- Swift helper binary: `/Applications/Wispr Flow.app/Contents/Resources/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow` (read with `nm -u`, `strings`, `otool -L`).
- Helper disassembly made by another agent: `/Users/sorcecoder/shepetal-agent/re/helper-disasm.txt` (only grepped).

## 1. Features

- **Hold to talk (PTT).** On Mac you hold fn by default. Release it to stop, transcribe and paste.
- **Double-tap for hands-free ("POPO" lock).** Press the PTT key twice within 500 ms and recording locks on. You do not have to keep holding. Press the key once more to stop.
- **Separate hands-free toggle.** On Mac this is fn+Space by default. One press starts and locks. The next press stops. Pressing it again within 500 ms of the start cancels.
- **Triple press cancels.** A third quick press inside the 500 ms window, while locked, throws the dictation away.
- **A tap that is too short is discarded.** If you release PTT within 500 ms and do not press again, the recording is dropped. You get a "hold the key" hint, and sometimes a modal that teaches you to hold.
- **Escape cancels.** The Dismiss action is Esc by default and can be rebound. You get a "transcript cancelled" notification. While a dictation is running, the helper swallows Esc, so the frontmost app never receives it.
- **Chord collision cancels.** If PTT started less than 1 s ago and you then press a key combination that is not a Wispr shortcut (for example fn plus another key), the dictation is dropped, because you were reaching for a different shortcut.
- **Upgrade from PTT to hands-free mid-hold.** If you hold fn and then add Space, the session's trigger is rewritten to the larger chord. It does not start a second session.
- **Other default actions (Mac):** command mode ("Lens") fn+Ctrl, paste last transcript Cmd+Ctrl+V, copy last transcript Cmd+Ctrl+C. There are also optional actions: scratchpad, polish prompts, focus mode Opt+F, meeting recorder Opt+M, and more.
- **Fallback shortcuts for keyboards without fn:** PTT Ctrl+Opt, hands-free Ctrl+Opt+Space, Lens Cmd+Ctrl+Opt.
- **Windows defaults** (useful as a Linux model): PTT Ctrl+Win, hands-free Ctrl+Win+Space, Lens Ctrl+Win+Alt, paste last Shift+Alt+Z, copy last Shift+Alt+X, Esc to dismiss.
- **Custom shortcuts:** at most 3 keys. They must include a modifier or a mouse button (Middle, Mouse 4 to 10, Aux). You cannot use both the left and right version of the same modifier. The app rejects duplicates and a blocklist of common OS shortcuts. Bare letters, digits and punctuation are not allowed.
- **Other ways to trigger:** clicking the floating bar (it has Cancel and Stop buttons), headset buttons (Jabra SDK, BLE devices), and deeplinks: `wispr-flow://start-hands-free`, `wispr-flow://stop-hands-free`, and `wispr-flow://switch-mic?mic_name=...`.
- **Max length:** a warning at 19 min ("stops in one minute"), then a forced stop and transcribe at 20 min.
- **Sounds:** start, stop, hands-free lock, paste, achievement, and notification success/error/alert sounds. There are about 9 selectable sound packs, and sounds can be turned off.
- **Media handling while dictating:** the app can mute system output, which is on by default on Windows only, and can pause playing media, which is off by default. It only does this when media is actually playing.
- **Mic selection:** an automatic best mic chosen from a ranked list you can edit. You can also force one device. It warns about a new mic, switches mics automatically, avoids the built-in mic when the lid is closed (clamshell), and can suggest a wired mic.
- **Floating "Flow bar" overlay states:** hidden, resting, context menu, initializing, ready, active PTT, active hands-free, processing, polish states, cleanup done, hotkey reminder, instruct done, and error. The bar has a 10-bar live waveform and can be dragged to a new place.
- **"Whisper mode"** is a coaching feature. Onboarding and the mic quiz teach you to whisper, and a `usedWhisperMode` stat is tracked. There is no separate whisper audio pipeline on the client.
- **Error states:** no mic, mic not readable, mic access timeout, mic disconnected mid-dictation, mic or accessibility permission revoked, Windows mic privacy off, no audio (silent mic), secure input blocking shortcuts, no internet, degraded network, and transcription error.

## 2. How it works

### 2.1 Where each part runs
- **Swift helper (Mac):** global keyboard capture, the Caps Lock and HID quirks, sounds played around muting, output mute and media pause/resume, mic privacy status, haptics, and pasting. It talks to Electron main over a typed JSON IPC called `HelperAPI`. The schema starts at `main@2487265` (`HelperAPIRequest` and `HelperAPIResponse` unions).
- **Electron main:** shortcut matching and the dictation state machine (`main@4371500` to `main@4393000`). It also sets timers and sends notifications.
- **Hub renderer (hidden window):** `getUserMedia`, the AudioContext and AudioWorklet, PCM or Opus encoding, silence detection, device ranking, and sound playback (`hub@711000` to `hub@802000`, class with the static `mediaOptions`).
- **Status renderer:** the floating bar UI (`status@2502` holds the indicator state enum).

### 2.2 fn and hotkey detection (Mac): CGEventTap, with IOHIDManager on the side
- The helper's class is `KeyboardService` (from strings). It imports `CGEventTapCreate`, `CGEventTapEnable`, `CGEventTapIsEnabled`, `CGEventGetFlags`, `CGEventSourceFlagsState` and `CGEventSourceKeyState`.
- `helper-disasm.txt` lines around 645039 and 645096 show the keyboard tap call. It is a session tap inserted at the head, with event mask `0x06001C00`: keyDown, keyUp, flagsChanged, otherMouseDown and otherMouseUp. It is created first with options 0, meaning an active tap that can swallow events. A second call with options 1 (listen-only) is the fallback or probe. Telemetry `keyboard.event_tap_create {listen_event, post_event, probe_listen_only, probe_keyboard_only}` (`main@5197900` area) matches this. Permission is preflighted with `CGPreflightListenEventAccess` and `CGPreflightPostEventAccess` (imports).
- Because the tap is active, the helper swallows events. Helper log lines (`helper-strings.txt:10014`-`10015`) and the `suppressedMouseButtons` field show it. It hides matched shortcut keys, bound mouse buttons, and Esc during dictation from the frontmost app. It also tracks which keys are down (`curKeysDown`) and buffers keyboard events, flushing them later (`helper-strings.txt:9993`).
- The other listen-only taps are a mouse-click "drop witness" (mask 0x2) and an input-event capture tap (`com.wispr-flow.input-event-capture.tap`).
- fn is detected as keycode 63 on flagsChanged (the shortcut keycode table at `main@2726303` maps `fn:63`). There is also a pseudo-key `doubleFn:179`, which is the Globe key keycode on newer Apple keyboards. Both are normalized to the label "fn".
- IOHIDManager is not used to detect fn. It is used for two other jobs.
  - **Caps Lock.** Helper evidence: `capsLockHIDManager` and the Caps Lock log lines around `helper-strings.txt:9970`. When Caps Lock is bound, the helper reads it at the HID level and undoes the lock toggle.
  - **Keyboard detection.** It checks whether the keyboard has an Apple fn key, and treats a third-party keyboard as having no fn key (`helper-strings.txt:8653`). The result goes to main as `HardwareInfo.hasAppleFnKey` together with `isClamshellMode`. If there is no fn key, main switches to the Ctrl+Opt fallback defaults (`Re` next to the Mac default map).
- **IPC:** the helper sends `KeypressEvent {eventType, index, key, inputType?}`. `index` is a sequence number; main logs a mismatch when the two counts drift (`main@5190970`). Main sends the shortcut set to the helper with `UpdateShortcuts`. Main also has a pending-event queue (`pushKeypressEvent` and `processQueue` at `main@5197900`).
- **Tap robustness:**
  - When macOS disables the tap, the helper sends `TapRecoveryEvent {disableType: timeout | user_input | watchdog_detected, reason: reenabled_callback | reenabled_watchdog | storm_exiting, staleCandidates[], windowCount}` and `TapState {tapEnabled}`. The helper also has `TapStormPolicy` (storm threshold and window).
  - Key-ups can be lost while the tap is off. Main then asks the helper `CheckStaleKeys {keycodes}`, and the helper answers `StaleKeysResponse` using `CGEventSourceKeyState`. Main then releases the confirmed-stale shortcut keys to end the dictation (`main@5190259`), with a 500 ms confirmation timer.
  - There is also "phantom chord" suppression and chord-defer verification (telemetry `keyboard.phantom_chord_suppressed` and `keyboard.chord_defer_verified`).
  - Secure input: `SecureInputStatus {blocked, ownerAppName, ownerBundleId, ownerIsFlow, ownerPid, secondsBlocked}`. When it is blocked, the user sees "SecureInputBlockingShortcuts" (`IsSecureEventInputEnabled` is imported).

### 2.3 Hold vs double-tap: the state machine (`main@4371500`–`main@4383500`)
The state lives in a global dictation object. It holds `status` (`initializing | listening | stopping | processing | dismissed | retrying | error | idle | testing`, at `main@2649510`), `isLocked` (the hands-free / POPO lock), `startTime`, `triggerShortcut` and `triggerKeycodes`.

All timing comes from the constants module (`59725` export list at `main@4312335`):
| Constant | Value | Use |
|---|---|---|
| `DICTATION_DEBOUNCE_DELAY` | 500 ms | Double-tap window, short-tap discard, and repeated-press cancel |
| `SCRATCHPAD_PTT_DELAY_MS` | 350 ms | Default hold threshold for extension/scratchpad keybinds |
| `MID_DICTATION_INSTRUCT_GRACE_MS` | 1000 ms | How long after start you can still switch dictation to instruct mode |
| `DICTATION_DURATION_WARNING_TIMEOUT` | 19 min | Warning notification |
| `DICTATION_DURATION_TIMEOUT` | 20 min | Forced stop (`forceStopped="max_duration"`) |
| `RECORDING_SAMPLE_RATE` | 16000 | |
| `CHUNK_DURATION_MS` | 40 | |

PTT key down (`Ve`):
- **When idle:** start dictating, unlocked.
- **When already listening or initializing, and less than 500 ms since start:**
  - If locked, dismiss with reason `debounce_triple_press`.
  - Otherwise lock: set `isLocked=true`, play the POPO lock sound, and send POPO to the status window.
- **While the previous transcript is still processing:** ignore the press and show a "transcript currently processing" notice.

PTT key up (`Ye`):
- **Locked:** ignored.
- **Listening and unlocked:**
  - Less than 500 ms since start: arm a 500 ms timer (`nt`). If no second press comes before it fires, dismiss with reason `debounce_ptt`. This is the "tap too short" case.
  - Otherwise stop and transcribe (`lt`).
- **Still initializing (mic not ready yet):**
  - Less than 500 ms since start: arm the same 500 ms timer.
  - Otherwise dismiss with `debounce_ptt`.

Dedicated hands-free toggle (`et`):
- **When idle:** start and lock.
- **When already locked:** within 500 ms of the start, dismiss with `debounce_popo`; otherwise stop.
- **A click on the status bar** follows the same path, with the source set to `status_indicator`.

Chord promotion (`He` / `Qe`): if a new chord is a strict superset of the current trigger (by key set), the active session's trigger is rewritten to the new chord. That is how fn followed by fn+Space turns PTT into hands-free.

Chord collision (`le`, `main@5184799`): if dictation is active and unlocked, less than 1 s has passed since start, and the keys now held do not match any Wispr shortcut, dismiss with `other_shortcut`.

Nudges after a dictation (`rt`):
- If the dictation was 60 s or longer and not locked, show a "try hands-free" tip after 3 s.
- If it was 10 min or longer, suggest the notetaker.

Dismiss reasons (`main@2650949`): `user_action_escape`, `user_action_cancel_button`, `other_shortcut`, `debounce_ptt`, `debounce_popo`, `debounce_triple_press`, `no_internet`, `long_initialization`, `excessive_duration_error`, `no_audio_during_dictation_error`, `get_user_media_abort`, `mic_acquisition_failed`, `audio_context_recovery`, `admin_policy_blocked`, and others.

Action sources: `keyboard`, `mouse`, `status_indicator`, `deeplink`, `error`, `ble`, `voice_actions_realtime`.

Generic keybind gesture engine for extensions (`main@5174401`, module `96635`):
- Gestures: `tap`, `doubleTap`, `holdStart`, `holdEnd`.
- Hold is detected with a timer at `holdThresholdMs`, default 350.
- Double-tap is detected when the gap between two presses is less than `doubleTapWindowMs`, default 500.
- A bare tap is reported only after the double-tap window has passed.

### 2.4 Shortcut model (`main@2726303`)
- A shortcut is a sorted list of keycodes joined with `+` and used as a map key. The value is an action from the action enum (`ptt`, `popo`, `dismiss`, `paste_last_text`, `copy_last_text`, `command`, `lens`, `polish`, `open_scratchpad`, `undo`, `toggle_focus_mode`, `open_meeting_recorder`, and others).
- The keycode table covers both platforms: macOS virtual keycodes and Windows VK codes. Mouse buttons are mapped to codes 4098 to 4105 and 65535.
- The validator returns the error codes `blocked`, `in_use`, `too_many_keys` (more than 3), `left_right_same` and `no_modifier`.
- `allowStandaloneKeys` lets some single keys through. The candidates are Caps Lock on Windows, plus Tab or Alt as alternatives.

### 2.5 Audio capture (hub renderer)
- **getUserMedia constraints** (`hub@711522`): `echoCancellation:false`, `noiseSuppression:false`, `autoGainControl:false`, `sampleRate:16000`, `channelCount:1`, plus `deviceId:{exact}` for the device the app picked.
  - The call is wrapped in a 3 s AbortController timeout (helper `rb`). AudioContext resume also gets 3 s. Repeated getUserMedia errors are de-duplicated over a 120 s window.
  - An aborted start (`hub@722164`) means the user released the key while still waiting for getUserMedia.
- **AudioContext** at 16 kHz with a latency hint. An AudioWorklet called `recorder-processor` buffers 640 samples per chunk (40 ms at 16 kHz) and posts each chunk. The main thread converts Float32 to Int16 PCM.
- **Opus encoding:** if WebCodecs `AudioEncoder` supports `{codec:'opus', sampleRate:16000, channels:1, bitrate:64000}`, audio goes out as 20 ms Opus packets. Otherwise WAV/PCM chunks are sent. There are also opusscript WASM workers in main: `opusEncoder.worker.js` and `incrementalOpusEncoder.worker.js`.
- **No client VAD and no silence trimming.**
  - There is no VAD or silero code in any bundle. The only "VAD" match is inside base64 data.
  - The silence logic only looks for chunks where every sample is exactly zero, which points to a dead mic or driver bug, not to speech silence.
  - Leading zero chunks before the first real audio are dropped. On a silent start the app reopens the mic once (`hub@785369`), again with a 3 s getUserMedia timeout.
  - Thresholds: `SILENCE_WARNING_THRESHOLD_CHUNKS=125` (5 s), `SILENT_START_WARNING_THRESHOLD_CHUNKS=150` (6 s), `SILENCE_ESCALATION_THRESHOLD_CHUNKS=375` (15 s). Crossing them shows mic-silence warnings, and NoAudioDuringDictationEscalated at 15 s. RecordingStoppedSilence (Stop now / Keep recording) belongs to the meeting recorder, not to dictation.
  - Main also stops the dictation if there are no audio packets at all after 5 s (`no_audio_during_dictation_error`, `main@4305999`).
- **Audio quality hint:** the server sends back `audioSnr`, `audioVolume` and `meanAlignmentScore` with the transcript (protobuf at `main@3706006`). The client compares them with feature-flag thresholds (defaults: SNR 5 dB, volume -70 dB, alignment 0.15) and shows "AudioQualityIssue" or "SuggestWiredMic".
- **Device selection:**
  - The user's ranked list is `rankedAudioDevices`. `overrideAudioDeviceId` forces one device.
  - `enumerateDevices` results are tagged `isBuiltIn`, `isBluetooth` and `isVirtual`.
  - On `devicechange`, the app re-picks a device and logs `MicAutoSwitched {reason: disconnect | rank_up}`. If the active mic disappears mid-dictation, it stops and shows MicDisconnected.
  - There is clamshell awareness (NoClamshellBuiltInMic) and a Jabra wear-detection override.
- **Codec and Bluetooth:** the helper's Volume Manager detects an output codec or sample-rate change on the default device. This happens when a Bluetooth headset drops to HFP once its mic opens. The helper waits up to 500 ms for the codec to settle before it mutes or unmutes (`helper-strings.txt:8625`).
- **Audio interruptions:** the helper sends `AudioInterruptionEvent {interruptionType: began | ended, deviceId, deviceName, deviceState, reason}`. It has a watchdog on hung CoreAudio HAL calls (`WatchdoggedAudioInterruptionAdapter`, `helper_error:audio_hal_watchdog`).

### 2.6 Muting, ducking and pausing media
- The prefs are `shouldMuteAudio` (default true on Windows, false on Mac) and `shouldPauseAudio` (default false) (`hub@196554`). Neither is a true volume duck. "Mute" sets the system output mute, or sets the output volume to zero and later restores it (CoreAudio `AudioObjectSetPropertyData`).
- The helper skips muting when media is not playing, when output is already silent, or when it cannot read the level. It keeps an "owed restore" for each device so it does not restore the wrong one.
- **Pause** uses the bundled `MediaRemoteAdapter.framework` (seen with `otool -L`), with class `MediaTransport` and `NowPlayingCache`. It sends pause, and resumes only if the app paused the media itself (`pausedByUs`). The helper pushes `IsMediaPlayingUpdate {isMediaPlaying, isKnownMediaPlaying, isMediaPausable}` to the renderer.
- **Order of events:** a helper log line (`helper-strings.txt:8616`) names the start sound before the mute, so the sound plays first and the mute follows. So the start chime stays audible even though output is about to be muted.

### 2.7 Sounds
- Sound packs (`hub@694253`, map `kf`): `default`, `v1` to `v7`, and `v7_2`. Each pack defines `start`, `stop`, `popoLock`, `paste` and `achievement`. All packs share the notification success, error and alert sounds.
- The prefs are `enableSounds` (default true) and `selectedSoundFolder`.
- The hub renderer plays the wav files. The helper's Volume Manager decides when: it sends `PlayDictationStartSound` / `PlayDictationStopSound` over HelperAPI, main relays them to the hub (`hub@714769`), and only then does the helper mute output. The hub also records whether media was playing just before the start sound (`mediaWasPlayingBeforeDictationSound`).
- Haptics: the helper uses `NSHapticFeedbackManager` for bubble hover (`HapticEvent: bubbleHover | bubbleUnhover`).

### 2.8 Overlay / Flow bar states (`status@2502`)
- Indicator states: `hidden`, `resting`, `context-menu`, `initializing`, `ready`, `active_ptt`, `active_popo`, `processing`, `polish_processing`, `polish_completed_action`, `polish_completed_na`, `polish_failed`, `auto_cleanup_completed`, `hotkey_reminder`, `instruct_completed`, `error`.
- Tooltips and buttons: bubble, cancel, stop, polish wand, language picker, scratchpad, and others (`status@272942`).
- The waveform has 10 bars by default. It is driven by the per-chunk volume level that the hub sends.
- Main pushes the dictation status, and the command-mode, instruct-mode and POPO flags, to the status window over IPC.
- If processing takes longer than 4 s, the user gets a "processing delay" notification.

### 2.9 Errors and permissions
- Notifications related to input (`main` notification enum): MicAccessError, MicAccessTimeout, MicDeviceUnavailable, MicDisconnected, MicNotFound, MicNotReadable, MicrophonePermissionRevoked, AccessibilityPermissionRevoked, WindowsMicPrivacyDisabled, NoAudio, NoAudioDuringDictation(+Escalated), AudioWorkletLoadError, AudioContextRecovery, SecureInputBlockingShortcuts, NoInternet, DegradedNetwork, TranscriptionError, DictationDurationWarning, DictationMaxDurationReached, TranscriptCancelled(+Detailed), DictationCancelledOtherShortcut, HelperLoadingError.
- Permission checks run in the helper: `AXIsProcessTrusted(WithOptions)`, the event-access preflights, and `GetMicrophonePrivacyStatus` (which returns `desktopAppAccessEnabled` and `microphoneAccessEnabled`).
- Onboarding tracks three permissions: accessibility, microphone and screen capture.

## 3. Local vs cloud
- **Local:** key capture, the state machine, timers, mic capture, Opus encoding, the dead-mic (all-zero) detection, device ranking, muting and pausing, sounds, and the overlay. Everything in this document's scope runs on the client.
- **Cloud:**
  - Speech recognition. Audio chunks stream to the backend (a gRPC client and "baseten" chunking: `basetenChunkSizeSeconds=28`, `STREAM_DEADLINE_MS` = 23 min).
  - The audio quality metrics `audioSnr`, `audioVolume` and `meanAlignmentScore`, which come back in the transcript response.
  - Feature flags that tune thresholds (for example `AudioQualityNotification`).
  - Admin or access policy that can block dictation (`admin_policy_blocked`).
- "Whisper mode" relies on the cloud model handling quiet speech. The client does no gain or DSP: AGC is off and the audio is raw.

## 4. What shepetal must build

Hotkeys and lifecycle
- [Mac] Hotkey capture via a CGEventTap at the session level, inserted at the head, listening for keyDown, keyUp, flagsChanged, otherMouseDown and otherMouseUp. Detect fn as keycode 63 with the secondary-fn flag on flagsChanged. Treat 179 (Globe) as fn as well. Needs the Input Monitoring / Accessibility permission. Preflight with `CGPreflightListenEventAccess`.
- [Mac] Re-enable the tap on `tapDisabledByTimeout` and `tapDisabledByUserInput`. Run a watchdog that polls `CGEventTapIsEnabled`. After any period with the tap off, reconcile held keys with `CGEventSourceKeyState` so dictation never gets stuck on.
- [Mac] Detect whether the keyboard has an Apple fn key. If it does not, default to Ctrl+Opt. IOHID is optional and only needed if Caps Lock binding is supported.
- [Mac] Watch `IsSecureEventInputEnabled` and tell the user when a password field is blocking shortcuts.
- [Linux] There is no fn key; the keyboard firmware handles it. Default PTT is Ctrl+Super (Windows analogue), and hands-free is Ctrl+Super+Space. Capture keys through evdev (`/dev/input/event*`, needs the `input` group). That works on both X11 and Wayland. Use XInput2 raw events as an X11-only fallback. Do the same stale-key reconciliation (`EVIOCGKEY`).
- [iPhone] No global hotkeys. The input is a keyboard extension mic button or an app/Shortcut/Action-button intent. Implement PTT as press-and-hold on the button and hands-free as a tap that toggles. The same state machine applies.
- [Mac/Linux] Swallow Esc and the matched shortcut events while dictating, so the frontmost app does not react to them. On Mac the active tap returns NULL. On Linux, evdev `EVIOCGRAB` is all-or-nothing, so this needs a uinput re-injection proxy, or the app accepts that the events pass through.
- [All] Port the state machine one to one:
  - A 500 ms window that does several jobs: double-tap to lock, discard a short tap, a third press to cancel, and a repeated press of the hands-free key to cancel.
  - Chord promotion from PTT to hands-free.
  - Cancel on a non-shortcut chord within 1 s.
  - Esc to dismiss.
  - Ignore presses while the previous transcript is still processing.
  - Make the timings configurable (hold threshold and double-tap window).
- [All] A shortcut editor with the same validation rules: at most 3 keys, a modifier or mouse button required, no left+right pair of the same modifier, no duplicates, and an OS blocklist. Support mouse buttons 3 to 10.
- [Mac/Linux] Deeplinks or a CLI for start-hands-free, stop-hands-free and switch-mic (custom URL scheme on Mac; D-Bus or CLI on Linux).
- [All] A 20 min max length with a 19 min warning. Make the value configurable, because with local ASR there is no cost reason to cap it.

Audio
- [Mac/Linux] Open the mic for each dictation, like Wispr does: `setupMediaStream` runs on every start while the AudioContext stays alive, so the OS mic indicator is only on while dictating. On stop, flush the partial last frame (the worklet's "stop" message sends the remaining samples). Capture 16 kHz mono with OS AEC, NS and AGC all turned off, in 40 ms frames. On Mac use AVAudioEngine or CoreAudio. On Linux use PipeWire or PulseAudio through cpal. Keep it as Int16 PCM in memory. Opus is not needed, because the audio never leaves the machine.
- [iPhone] Use AVAudioSession `.record` / `.playAndRecord` at 16 kHz mono with `.measurement` mode (no processing).
- [All] Detect a dead mic: if every sample is zero for 5 s, warn. If there are no frames at all within 5 s, stop. If the start is silent, reopen the device once. Put a 3 s timeout on opening the mic.
- [All] Add a local VAD as a step beyond what Wispr does: Silero VAD (ONNX) or WebRTC VAD. Use it to trim leading and trailing silence before the local ASR, and optionally to auto-stop hands-free after N seconds of silence. Wispr does neither on the client.
- [All] Compute a local quality hint to replace the server-side SNR: RMS level and SNR estimated from VAD speech and non-speech frames. Show a "move closer or use a wired mic" hint.
- [Mac/Linux] Mic picker with a user-ranked list, auto-switch on hot-plug, stop and notify if the active mic disappears mid-dictation, and on Mac skip the built-in mic in clamshell mode. Linux needs PipeWire device-change events.
- [Mac] Handle Bluetooth HFP: expect the output codec or sample rate to change when the mic opens, and wait about 500 ms before muting or restoring.

Media, sounds, UI
- [Mac] Optional mute while dictating: zero the system output with CoreAudio, only if media is playing, and restore it per device. Optional pause of media through MediaRemote. Since macOS 15.4 this needs an adapter like the one Wispr bundles; the open-source mediaremote-adapter approach is one option. Resume only media the app paused itself.
- [Linux] Pause with MPRIS (`org.mpris.MediaPlayer2.Player.Pause` over D-Bus) and resume only the players the app paused. Mute or duck with `wpctl set-mute` / `pactl`, or with PipeWire per-stream volume for a real duck.
- [iPhone] An AVAudioSession category with `.duckOthers` or interruption gives ducking for free.
- [All] Our own original start, stop, lock and cancel sounds, with a toggle. Play the start sound before muting.
- [Mac/Linux] A floating overlay with a matching state set: hidden, resting, initializing, active-PTT, active-hands-free (with cancel and stop buttons), processing, error. Include a live level waveform and a draggable position. On Linux use a layer-shell overlay on Wayland (wlr-layer-shell; GNOME has no layer-shell, so a fallback is needed) or an override-redirect window on X11.
- [All] Clear error states: mic permission missing or revoked (with a deep link to settings), no mic, mic busy or not readable, getUserMedia timeout, accessibility or input-monitoring permission missing, secure input active.

## 5. Open questions
- Esc and matched shortcut events are swallowed (from strings). It is still unknown whether a bare fn press is also swallowed, which would stop the macOS emoji picker or the "Press fn to start Dictation" action, or whether users have to change that macOS setting. To check, trace the tap callback in `helper-disasm.txt` near line 645039.
- The exact fn detection inside the callback: does it read the keycode alone, or `kCGEventFlagMaskSecondaryFn`? Wispr also has a `doubleFn` (179) pseudo-key, and it is unclear whether that is the Globe key or a synthesized double-press.
- Does the helper apply any timing of its own before it emits `KeypressEvent`, or is all of the 500 ms logic in main? It looks like everything is in main.
- Whether Wispr reads or changes the macOS "Press fn key to" setting (`AppleFnUsageType`). No string for it was found.
- How `usedWhisperMode` gets set: by a server-side whisper classifier, or by the quiet-volume heuristic?
- Whether auto-stop on silence exists anywhere for hands-free mode. Nothing was found on the client; it might come from the server.
- REA was not run in this sprint. `nm`, `strings` and the existing disassembly were enough for this scope.
