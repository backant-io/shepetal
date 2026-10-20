# Shepetal for iPhone

On-device dictation in any app, through a custom keyboard. No server, no network: speech is transcribed on the iPhone with [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3, CoreML).

## Architecture

iOS does not give keyboard extensions the microphone, and caps their memory (about 48 MB, undocumented). So the work is split across two processes:

| Target | Role |
|---|---|
| `Shepetal` (app) | A thin shell: the `AVAudioEngine` mic (under the `audio` background mode, so it keeps listening after the user goes back to their app), the FluidAudio model, the UI (status, Cancel, history, the 24 h retention toggle, Donate links). All decisions are made by `DictationSession`. |
| `ShepetalKeyboard` (keyboard extension) | A mic button, globe and delete, and the 🤫 indicator in the bottom-left corner with the dictation state next to it. No audio, no model. Inserts the result with `textDocumentProxy.insertText`. |
| `ShepetalSessionCore` (framework) | `DictationSession` (the app's dictation flow behind a `Microphone` protocol and a transcribe closure), the handoff state machine (`Handoff`), the App Group transport (`SharedHandoff`), the audio and history archive (`AudioArchive`, `Recording`, used only by the app) and the keyboard's `Indicator`. |
| `ShepetalSessionCoreTests` | Unit tests for all of the above. `DictationSessionTests` runs the app's flow with a fake mic and a fake model. |

Handoff, through the App Group `group.io.backant.shepetal` (shared `UserDefaults` holds the state, Darwin notifications are the doorbell):

```
keyboard: request(id)  ──open shepetal://dictate?id=──▶  app: startRecording(id)       idle → requested → recording
user goes back with the iOS back control, taps the mic again
keyboard: post "stop"  ─────────────────────────────▶  app: finishRecording(id)      → transcribing
                                                        app: deliver(id, text), post "ready"  → ready
keyboard: consume(id) → insertText                                                    → inserted
                                    or app: fail(id, why) / cancel(id), post "ready"  → failed / cancelled
```

Rules the tests enforce (`Tests/HandoffTests.swift`, `Tests/DictationSessionTests.swift`). Each one has a test that fails if it regresses:
- **The mic only starts for a request the keyboard wrote.** Any app can open `shepetal://dictate?id=…`. `DictationSession.open` first checks that the shared state is `requested`, the id matches and the request has not expired (`canStart`). Only then does it ask for mic permission, check again (the same URL may have been opened twice while the prompt was up), claim the session and start the mic (`startRecording(id) { mic.start() }`). If the mic fails to start, the session fails and the keyboard says why. One request starts the mic once.
- **A recording stops itself.** One dictation is capped at 5 minutes (`Handoff.maxRecording`, the same cap Wispr uses). Once a second, `DictationSession.tick` stops the recording when the mic is no longer running, when the shared state no longer shows its own session in `recording` (a new session was requested or it was cancelled), or at the cap. A recording still open 60 s after the cap is treated as abandoned and expires.
- **A dead mic ends the recording.** A call, Siri, another app taking the audio session, or a route or hardware change stops `AVAudioEngine`. The app stops the recording right away on an interruption, and the once-a-second tick catches any other case through `engine.isRunning`. Recording does not resume on its own. What was captured is kept and transcribed, and the keyboard shows "Recording stopped early" next to the inserted text.
- **The keyboard is told how every dictation ends.** Too short (under 0.3 s, which the model rejects), model still loading, transcription error, mic permission off, mic failed to start, result shown in another field, cancelled, timed out: each one shows its reason next to 🤫 instead of "Transcribing..." until the session expires.
- **Text goes only into the field it was dictated for.** The keyboard stores `textDocumentProxy.documentIdentifier` with the request. A ready result shown in any other field is never inserted; the keyboard says the text is in Shepetal's history.
- The keyboard only inserts text for the session id it requested. A late result from an older session is rejected (it is still transcribed into history), and a result is inserted at most once.
- `requested`, `transcribing` and `ready` expire after `Handoff.timeout` (60 s) without progress.
- **The 🤫 indicator** is an 18 pt label 8 pt from the keyboard's bottom-left corner, always shown while the keyboard is up, with the state text next to it (`Indicator`, `IndicatorTests`).

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

The simulator has no usable mic path for this flow, so the end-to-end test runs on a device.

1. Open `Shepetal.xcodeproj`, set your team on the `Shepetal` and `ShepetalKeyboard` targets, and make sure both have the App Group `group.io.backant.shepetal` (change the id in `project.yml` and `Core/Handoff.swift` if your team cannot register it).
2. Run `Shepetal` on the iPhone. Wait for "Ready" (the first launch downloads the model).
3. Settings > General > Keyboard > Keyboards > Add New Keyboard > Shepetal. Tap Shepetal and turn on **Allow Full Access** (needed for the shared App Group container; the keyboard makes no network calls).
4. Open Notes, switch to the Shepetal keyboard with the globe key, tap the mic.
5. Shepetal opens and asks for the microphone the first time. Allow it. The status reads "Listening".
6. Go back to Notes with the back control in the top-left corner of the status bar. Speak.
7. Tap the mic on the keyboard. The text appears in the note.

Checks:
- With Full Access off, the keyboard asks you to turn it on.
- From Safari, open `shepetal://dictate?id=00000000-0000-0000-0000-000000000000`. The app must say it ignored the request, and the mic indicator must stay off.
- Start a dictation, go back to Notes, then tap into a different note or app before stopping. Nothing may be inserted there.
- Start a dictation and leave it running. The mic indicator must go off after 5 minutes and the text must still arrive.
- Start a dictation and tap Cancel in the app. `audio/<id>.wav` and `audio/<id>.json` (outcome `cancelled`) are still in the app container (Xcode > Devices > Download Container). The keyboard shows "Cancelled".
- The keyboard shows 🤫 in its bottom-left corner at all times, and the state next to it.
- Start a dictation, then take a call or ask Siri something. The recording stops, and what was said before is inserted with "Recording stopped early" next to 🤫. Do the same by connecting AirPods.
- Tap the mic and stop it at once (under 0.3 s). The keyboard shows "Too short", and the app history lists the recording as `tooShort`.
- Start a dictation, lock the iPhone and wait past the 5-minute cap. The app shows that the recording is not saved yet. Unlock: the message goes away and `audio/<id>.wav` exists.
- With iCloud Backup on, check Settings > [your name] > iCloud > Manage Account Storage > Backups > this iPhone > Shepetal: the audio must not count toward the backup size. Confirm in a downloaded container that `Library/Application Support/audio` has the backup-exclusion attribute.
- Turn on "Delete recordings after 24 h", come back a day later and open the app: recordings older than 24 h are gone from the list and the container.
- The Donate links in the app open https://buymeacoffee.com/sorcecoder and https://github.com/sponsors/backant-io.
- Tap the mic, wait more than 60 s before going back, then confirm nothing is inserted.
- Check that `documentIdentifier` stays the same when the keyboard process is relaunched in the same field. If it does not, the field check will discard every result. This is not verified yet.

## Not done yet

- **🤫 in the Live Activity / Dynamic Island** (product rule 3, iPhone part). Only the keyboard corner has it. Live Activity and `AudioRecordingIntent` (Action Button, Control Center, Shortcuts) are not built.
- **History replay and re-transcription with another model** (product rule 4, "what it's for"). The history list shows outcome and text only; there is no player and no per-recording delete.
- **24 h deletion runs only while the app runs** (launch, foreground, after each save). iOS gives an app no timer while it is not running, so a recording can outlive 24 h until the app is next opened. A `BGAppRefreshTask` would narrow the gap.
- **Audio held in memory while the iPhone is locked is lost if iOS kills the app before unlock.** Writing it with `.completeUnlessOpen` would avoid that but breaks the "FileProtectionType.complete" rule.
- The app shell itself (AVAudioEngine wiring, the interruption observer, the SwiftUI view with history, toggle and Donate links) has no automated test; everything it decides is in `DictationSession`, which is tested. The view is a hand test.
- Keeping the session open across several dictations without bouncing to the app (Wispr keeps the mic on for 5 minutes).
- A cancel button on the keyboard. Cancel exists in the app only.
- Text cleanup and personal dictionary.
- A real device run. Only the simulator build and unit tests are verified.
