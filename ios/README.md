# Shepetal for iPhone

On-device dictation in any app, through a custom keyboard. No server, no network: speech is transcribed on the iPhone with [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3, CoreML).

## Architecture

iOS does not give keyboard extensions the microphone, and caps their memory (about 48 MB, undocumented). So the work is split across two processes:

| Target | Role |
|---|---|
| `Shepetal` (app) | A thin shell: the `AVAudioEngine` mic (under the `audio` background mode, so it keeps listening after the user goes back to their app), the FluidAudio model, the Live Activity (`LiveIndicator`), the UI (status, Cancel, "Keep the microphone open" with "Turn off the microphone", history, the 24 h retention toggle, Donate links). All decisions are made by `DictationSession`. |
| `ShepetalKeyboard` (keyboard extension) | A mic button, globe and delete, and the 🤫 indicator in the bottom-left corner with the state ring and the dictation state next to it. No audio, no model. Inserts the result with `textDocumentProxy.insertText`. |
| `ShepetalWidget` (widget extension) | Draws the Live Activity: 🤫 with the state ring on the lock screen and in the Dynamic Island (compact, minimal and expanded). |
| `ShepetalSessionCore` (framework) | `DictationSession` (the app's dictation flow behind a `Microphone` protocol and a transcribe closure), the handoff state machine (`Handoff`), the App Group transport (`SharedHandoff`), the audio and history archive (`AudioArchive`, `Recording`, used only by the app), the `Indicator` with its states and colors, and the Live Activity's `DictationActivity`. |
| `ShepetalSessionCoreTests` | Unit tests for all of the above. `DictationSessionTests` runs the app's flow with a fake mic and a fake model. |

Handoff, through the App Group `group.io.backant.shepetal` (shared `UserDefaults` holds the state, Darwin notifications are the doorbell):

```
keyboard: request(id)  ──open shepetal://dictate?id=──▶  app: startRecording(id)       idle → requested → recording
user goes back with the iOS back control, taps the mic again
keyboard: requestStop(id), post "stop"  ────────────▶  app: finishRecording(id)      → transcribing
                                                        app: deliver(id, text), post "ready"  → ready
keyboard: consume(id) → insertText                                                    → inserted
                                    or app: fail(id, why) / cancel(id), post "ready"  → failed / cancelled

while the app's mic stays open (its heartbeat in the App Group is under 3 s old):
keyboard: request(id), post "start"  ───────────────▶  app: startRecording(id), no app switch
```

Rules the tests enforce (`Tests/HandoffTests.swift`, `Tests/DictationSessionTests.swift`). Each one has a test that fails if it regresses:
- **The mic only starts for a request the keyboard wrote.** Any app can open `shepetal://dictate?id=…`. `DictationSession.open` first checks that the shared state is `requested`, the id matches and the request has not expired (`canStart`). Only then does it ask for mic permission, check again (the same URL may have been opened twice while the prompt was up), claim the session and start the mic (`startRecording(id) { mic.start() }`). If the mic fails to start, the session fails and the keyboard says why. One request starts the mic once.
- **The stop notification is only a doorbell.** Darwin notifications carry no sender, so any app can post "stop". The keyboard first writes `requestStop(id)` into the App Group, which other apps cannot write, then posts. The app (`DictationSession.followKeyboard`) stops only when the shared state holds a stop request, or a cancel, for the recording it is making; a bare notification changes nothing (issue #14). The once-a-second tick runs the same check, so a lost notification costs at most a second.
- **The mic stays open between dictations, and only a dictation's own frames are kept.** iOS lets an app start recording only while it is in front, so the first dictation opens Shepetal. After it, the app keeps the mic running in the background for "Keep the microphone open" (5 minutes by default; also after each dictation, 15 minutes or 1 hour, which stays under the 8 hours after which iOS ends a Live Activity), shows "Ready" in the Live Activity, and writes a heartbeat into the App Group every second. While the heartbeat is fresh, the keyboard writes its request and posts "start" instead of opening the app; the app starts recording from the request (the notification is only a doorbell, like "stop"), and the tick picks up a request whose notification got lost. If the app has not taken the request after 1.5 s, the keyboard opens it after all. Audio heard between dictations is dropped, never kept. The mic closes when its time runs out, when the system stops it (call, Siri, route change), or from "Turn off the microphone"; the next dictation then opens the app again. While idle, the mic tap drops each buffer before converting it (`Microphone.capturing`), and "Ready" is sent to the Live Activity again every minute, so it only goes stale (and shows "Stopped") when the app is no longer running.
- **Why the `audio` background mode keeps the input running between dictations** (what App Review will ask): only so the keyboard can start the next dictation without sending the user to the app, which iOS requires for starting a recording. Nothing heard between dictations is kept or converted. iOS shows the orange mic dot the whole time, and 🤫 "Ready" sits in the Live Activity. The user picks how long it stays open (or "Close after each dictation"), and "Turn off the microphone" ends it at once. The audio session mixes with other apps and keeps their audio on the loudspeaker or on AirPods in full quality (`.defaultToSpeaker`, `.allowBluetoothA2DP`).
- **A recording stops itself.** One dictation is capped at 5 minutes (`Handoff.maxRecording`, the same cap Wispr uses). Once a second, `DictationSession.tick` stops the recording when the mic is no longer running, when the shared state no longer shows its own session in `recording` (a new session was requested or it was cancelled), or at the cap. A recording still open 60 s after the cap is treated as abandoned and expires.
- **A dead mic ends the recording.** A call, Siri, another app taking the audio session, or a route or hardware change stops `AVAudioEngine`. The app stops the recording right away on an interruption, and the once-a-second tick catches any other case through `engine.isRunning`. Recording does not resume on its own. What was captured is kept and transcribed, and the keyboard shows "Recording stopped early" next to the inserted text.
- **The keyboard is told how every dictation ends.** Too short (under 0.3 s, which the model rejects), model still loading, transcription error, mic permission off, mic failed to start, result shown in another field, cancelled, timed out: each one shows its reason next to 🤫 instead of "Transcribing..." until the session expires.
- **Text goes only into the field it was dictated for.** The keyboard stores `textDocumentProxy.documentIdentifier` with the request. A ready result shown in any other field is never inserted there (goal rule 8). The keyboard puts it on the clipboard as plain text instead (local only, so Universal Clipboard does not send it to other devices; the old clipboard is not restored) and says to tap the field and choose Paste. If the clipboard write does not land (`Clipboard.copy` checks the change count and the text), the keyboard says the text is in Shepetal's history instead of telling the user to paste. A note delivered with the text (for example the 5-minute cap) stays after the hint. Without Full Access the keyboard cannot read the App Group at all, so it says to turn Full Access on and that the text is in history. The app keeps every result in history either way.
- The keyboard only inserts text for the session id it requested. A late result from an older session is rejected (it is still transcribed into history), and a result is inserted at most once.
- `requested`, `transcribing` and `ready` expire after `Handoff.timeout` (60 s) without progress.
- **The 🤫 indicator** is an 18 pt emoji 8 pt from the keyboard's bottom-left corner, always shown while the keyboard is up, with the state text next to it (`Indicator`, `IndicatorTests`). A ring around it shows the state in the Mac's colors: red while recording, blue while opening the app or transcribing, yellow for an error or a timeout, none when idle (`Handoff.indicatorMode`).
- **The Live Activity** shows 🤫 with the same ring and the state word ("Listening", "Transcribing", "Not inserted", "Ready") on the lock screen and in the Dynamic Island while the mic is open. The app starts it when recording starts (the app is in front then, which ActivityKit requires), updates it while transcribing, shows "Ready" between dictations while the mic stays open, and ends it when the mic closes. An error shows for about 4 s, then goes back to "Ready", or ends the Live Activity if the mic is closed. A recording that was superseded never ends the newer recording's Live Activity (`DictationSessionTests.testLiveActivity*`). If the user turned Live Activities off for Shepetal, dictation works the same without it.

### Raw audio is kept

The app saves the raw audio of **every** dictation (transcribed, cancelled, too short, failed, superseded, capped, interrupted) in its own `Application Support/audio/<session id>.wav`, next to a history entry `<session id>.json` (date, outcome, text, note). The WAV holds the exact 16 kHz mono samples given to the model, as 32-bit float WAV. Both are written with `FileProtectionType.complete`. The directory is excluded from iCloud and device backup (`isExcludedFromBackup`), so the audio never leaves the iPhone. It sits in the app's container, not the App Group, so the keyboard cannot read it.

- **Locked iPhone.** Files with complete protection cannot be created while the iPhone is locked. If a recording ends then (for example the 5-minute cap hits while locked), its audio and entry stay in memory, the app shows that they are not saved yet, and it writes them when protected data becomes available after unlock. The next dictation does not drop them.
- **Retention.** Keep (the default) or delete after 24 h, a toggle in the app. Deletion runs on launch, when the app comes to the front and after every save.
- **History.** The app lists every recording with its outcome and text (selectable, so text that was not inserted can be copied).

## Build and test

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is generated and not committed.

```sh
cd ios
xcodegen generate
xcodebuild -scheme Shepetal -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build test
```

The speech model (several hundred MB) downloads from Hugging Face into the app's Application Support folder on first launch. Model weights are never committed.

## Manual test on a real iPhone

The simulator has no usable mic path for this flow, so the end-to-end test runs on a device. The steps are in [`docs/manual-test.md`](../docs/manual-test.md#iphone) (I-SETUP-1 to I-DOCID-1).

## Not done yet

- **`AudioRecordingIntent`** (Action Button, Control Center, Shortcuts) is not built. The Live Activity starts only from the keyboard's mic.
- **History replay and re-transcription with another model** (product rule 4, "what it's for"). The history list shows outcome and text only; there is no player and no per-recording delete.
- **24 h deletion runs only while the app runs** (launch, foreground, after each save). iOS gives an app no timer while it is not running, so a recording can outlive 24 h until the app is next opened. A `BGAppRefreshTask` would narrow the gap.
- **Audio held in memory while the iPhone is locked is lost if iOS kills the app before unlock.** Writing it with `.completeUnlessOpen` would avoid that but breaks the "FileProtectionType.complete" rule.
- The app shell itself (AVAudioEngine wiring, the interruption observer, the SwiftUI view with history, toggle and Donate links) has no automated test; everything it decides is in `DictationSession`, which is tested. The view is a hand test.
- The Live Activity's ActivityKit calls (`LiveIndicator` in the app) and the widget's views have no automated test. What they show comes from `DictationSession.activity` and `Indicator.Mode`, which are tested; the rest is hand test I-LA-1.
- The keyboard's 🤫 has not been seen on screen. In the simulator the keyboard comes up with its indicator in the bottom-left corner, but a simulator booted without the Simulator app draws every emoji as a "?" box, in any app. The glyph and the ring colors are hand test I-IND-1.
- The keyboard's 1.5 s fallback (opening the app when the start notification was not taken) has no automated test; extension UI is not testable in this target. It is hand test I-OPEN-1 step 7.
- A cancel button on the keyboard. Cancel exists in the app only.
- Text cleanup and personal dictionary.
- A real device run. Only the simulator build and unit tests are verified.
