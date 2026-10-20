# Shepetal for iPhone

On-device dictation in any app, through a custom keyboard. No server, no network: speech is transcribed on the iPhone with [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3, CoreML).

## Architecture

iOS does not give keyboard extensions the microphone, and caps their memory (about 48 MB, undocumented). So the work is split across two processes:

| Target | Role |
|---|---|
| `Shepetal` (app) | Owns the mic and the speech model. Records with `AVAudioEngine` under the `audio` background mode so it keeps listening after the user goes back to their app, then transcribes with FluidAudio. |
| `ShepetalKeyboard` (keyboard extension) | A mic button, globe and delete. No audio, no model. Inserts the result with `textDocumentProxy.insertText`. |
| `ShepetalSessionCore` (framework) | The handoff state machine (`Handoff`), the App Group transport (`SharedHandoff`) and the audio archive (`AudioArchive`, used only by the app). |
| `ShepetalSessionCoreTests` | Unit tests for the state machine and the audio archive. |

Handoff, through the App Group `group.io.backant.shepetal` (shared `UserDefaults` holds the state, Darwin notifications are the doorbell):

```
keyboard: request(id)  ──open shepetal://dictate?id=──▶  app: startRecording(id)       idle → requested → recording
user goes back with the iOS back control, taps the mic again
keyboard: post "stop"  ─────────────────────────────▶  app: finishRecording(id)      → transcribing
                                                        app: deliver(id, text), post "ready"  → ready
keyboard: consume(id) → insertText                                                    → inserted
```

Rules the tests enforce (`Tests/HandoffTests.swift`). Each one has a test that fails if it regresses:
- **The mic only starts for a request the keyboard wrote.** Any app can open `shepetal://dictate?id=…`. The app first checks that the shared state is `requested`, the id matches and the request has not expired (`canStart`). Only then does it claim the session and start the engine (`startRecording(id) { startEngine }`). If the engine fails to start, the session rolls back to `idle`. One request starts the mic once.
- **A recording stops itself.** One dictation is capped at 5 minutes (`Handoff.maxRecording`, the same cap Wispr uses). Once a second, the app checks `shouldKeepRecording` and stops the engine as soon as the shared state no longer shows its own session in `recording`: when a new session is requested, when the session is cancelled, or when it reaches the cap. The keyboard sends stop before it requests a new session. A recording still open 60 s after the cap is treated as abandoned and expires.
- **Text goes only into the field it was dictated for.** The keyboard stores `textDocumentProxy.documentIdentifier` with the request. A ready result shown in any other field is discarded, never inserted.
- The keyboard only inserts text for the session id it requested. A late result from an older session is rejected, and a result is inserted at most once.
- `requested`, `transcribing` and `ready` expire after `Handoff.timeout` (60 s) without progress.

### Raw audio is kept

The app saves the raw audio of **every** dictation, cancelled ones included, in its own `Application Support/audio/<session id>.wav`. The file holds the exact 16 kHz mono samples given to the model, as 32-bit float WAV, written with `FileProtectionType.complete`. It sits in the app's container, not the App Group, so the keyboard cannot read it. Nothing deletes these files: cancelling marks the session `cancelled` and keeps the WAV. There is no setting to turn this off. Users should be told about it before shipping.

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
- Start a dictation and tap Cancel in the app. `audio/<id>.wav` is still in the app container (Xcode > Devices > Download Container).
- Tap the mic, wait more than 60 s before going back, then confirm nothing is inserted.
- Check that `documentIdentifier` stays the same when the keyboard process is relaunched in the same field. If it does not, the field check will discard every result. This is not verified yet.

## Not done yet

- Keeping the session open across several dictations without bouncing to the app (Wispr keeps the mic on for 5 minutes).
- Live Activity and `AudioRecordingIntent` (Action Button, Control Center, Shortcuts), described above.
- A way for the user to see or delete the kept audio.
- A cancel button on the keyboard. Cancel exists in the app only.
- Text cleanup, personal dictionary, history of late results.
- A real device run. Only the simulator build and unit tests are verified.
