# Manual tests

Steps a person has to run: they need physical keys, a voice, or a permission grant. Automated checks are not repeated here.

## Mac

Setup: install the app once, either from the release zip (README > Mac > Install) or with `scripts/make-app.sh --install`, which builds it and installs it to `/Applications/Shepetal.app`. Open it from Finder or with `open /Applications/Shepetal.app`. If the 🌐/fn key opens the emoji picker or starts macOS Dictation, set System Settings > Keyboard > "Press 🌐 key to" to "Do Nothing". If Wispr Flow is running with fn as its shortcut, both apps hear fn and both insert text: quit Wispr Flow (or move its shortcut off fn) before testing Shepetal.

The app is signed with a certificate when the build machine has one (`scripts/make-app.sh` prints "Signed with: …"). Then macOS keeps the permissions across rebuilds and updates. If it prints "Signed ad-hoc", every rebuild counts as a new app for macOS and the permissions have to be granted again. To run the M-PERM tests from scratch, quit Shepetal and reset its grants with `tccutil reset All io.backant.shepetal`.

### M-SETUP-1: first run from the installer
1. In System Settings > Keyboard, set "Press 🌐 key to" to Change Input Source (to see the installer fix it).
2. Download `Shepetal-<version>.pkg` from the release and open it (right-click › Open, or Privacy & Security › Open Anyway if macOS blocks it). Click Continue, Install, enter your password.
3. Expected: when the installer finishes, Shepetal opens by itself: no Dock icon, 🤫 in the menu bar and, tiny, in the bottom-left corner. The permissions window opens.
4. Expected: System Settings > Keyboard shows "Press 🌐 key to: Do Nothing" (reopen the pane), and pressing fn no longer switches the input source. System Settings > General > Login Items & Extensions lists Shepetal under Open at Login, and the 🤫 menu shows Start at login checked.
5. Grant Microphone, Input Monitoring and Accessibility. Expected: each row turns ✅ and the 🤫 menu's first line reads "Hold fn to talk, double-tap for hands-free".
6. Click into any text field, hold fn, say a sentence, release. Expected: the sentence is typed there.

### M-SETUP-4: the 🌐 key at launch, restore and uninstall
1. Quit Shepetal. Set "Press 🌐 key to" to Show Emoji & Symbols. Open Shepetal.
2. Expected: "🌐 key set to Do Nothing so fn can dictate" next to 🤫 for a few seconds, and the setting reads Do Nothing. Quit and open Shepetal again: no message this time.
3. In the 🤫 menu choose Restore 🌐 key setting (Change Input Source, the value it first replaced). Expected: the setting is back to that value.
4. Run `/Applications/Shepetal.app/Contents/Resources/uninstall.sh`. Expected: Shepetal quits, is gone from /Applications and from Login Items, the 🌐 key setting is what it was before Shepetal changed it, and `~/Library/Application Support/Shepetal` is still there.

### M-SETUP-5: fn not received
1. In System Settings > Privacy & Security > Input Monitoring, turn Shepetal off. Hold fn for 2 s.
2. Expected: a yellow ring and "fn not received: re-grant Input Monitoring" next to 🤫; Open Shepetal… > Home shows the same under fn problem. Turn Shepetal back on: within 2 s fn dictates again.

### M-SETUP-2: permissions survive a rebuild
1. With all three permissions granted, quit Shepetal, run `scripts/make-app.sh --install` (it must print "Signed with: Apple Development…" or "Developer ID…"), and open the app again.
2. Expected: no Permissions window opens, nothing is asked again, and fn dictation works straight away.

### M-SETUP-3: stays running in the background
1. Open Shepetal and use other apps for an hour, including full-screen apps and Space switches.
2. Expected: 🤫 is still in the bottom-left corner and in the menu bar, there was never a Dock icon, and fn still dictates. Quit Shepetal from the 🤫 menu: both 🤫 disappear.

### M-PERM-1: Microphone
1. Quit Shepetal. Run `tccutil reset Microphone io.backant.shepetal`.
2. Open Shepetal. The Permissions window lists Microphone with ⚠️.
3. Click Grant… next to Microphone. macOS asks for microphone access. Allow it.
4. Expected: the row turns ✅ within a second.

### M-PERM-2: Input Monitoring
1. Run `tccutil reset ListenEvent io.backant.shepetal` and open Shepetal.
2. Click Grant… next to Input Monitoring. System Settings opens at Privacy & Security > Input Monitoring. Turn on Shepetal.
3. Expected: the row turns ✅, and within 2 s the 🤫 menu's first line reads "Hold fn to talk, double-tap for hands-free". You don't need to restart.

### M-PERM-3: Accessibility
1. Run `tccutil reset Accessibility io.backant.shepetal` and open Shepetal.
2. Click Grant… next to Accessibility. Allow it in the prompt or in System Settings > Privacy & Security > Accessibility.
3. Expected: the row turns ✅.

### M-PERM-4: no prompts mode
1. Reset all three permissions as above. Run `open dist/Shepetal.app --args --no-permission-prompts`.
2. Expected: no macOS permission dialog appears and no Permissions window opens. 🤫 shows a yellow ring and "Needs Microphone, Input Monitoring, Accessibility" for about 4 s. Pressing fn does nothing.

### M-IND-1: indicator placement
1. With Shepetal running, look at the bottom-left corner of the main display (the one with the menu bar).
2. Expected: a small 🤫 (about 18 pt) about 8 pt from the bottom and left edges, above the Dock.
3. Switch to another Space, then put Safari in full screen. Expected: 🤫 stays in the same corner in both.
4. Click on 🤫. Expected: the click goes to whatever is under it. Shepetal does not take focus.
5. Tap fn once briefly. Expected: the hint shows to the right of 🤫, and 🤫 itself does not move. When the hint goes, 🤫 stays (idle has no ring).
(The frame, the panel flags, the hint timing and the ring colours are covered by `IndicatorTests`. This step checks them on a real display, Space and full-screen app.)

### M-FN-1: hold to talk
1. Click into a TextEdit document. Hold fn, say "Testing one two three, this is a hold to talk check.", then release.
2. Expected: a red ring while you hold, a pulsing blue ring after release, then the text appears at the cursor. Your earlier clipboard is back (Cmd+V elsewhere pastes what you had copied before).

### M-FN-2: double-tap for hands-free
1. In TextEdit, tap fn twice quickly (the second press within half a second of releasing the first).
2. Expected: the ring turns orange and stays orange after you release.
3. Speak two sentences without holding anything. Tap fn once.
4. Expected: the text appears. Recent in the 🤫 menu shows it.

### M-FN-3: short press
1. Tap fn once, briefly (under half a second), and don't tap again.
2. Expected: nothing is inserted. "Hold fn to talk · double-tap for hands-free" shows next to 🤫 for about 2 s.
3. Expected: Recent in the 🤫 menu has a "(too short)" entry, and a new WAV is in Open recordings folder.

### M-FN-4: fn as a modifier
1. In a long TextEdit document, hold fn and press Down arrow within the first second, keep both held for about 2 s, then release.
2. Expected: the view pages down. No ring stays red, nothing is transcribed or pasted, and no hint shows.
3. Type a word, then press fn+Delete quickly a few times.
4. Expected: characters after the cursor are deleted, nothing is inserted, and no hint shows. Recent in the 🤫 menu has a "(cancelled)" entry for each press, and each has a WAV in Open recordings folder.
5. Hold fn for about 2 s, then press Down arrow while still holding and speaking. Expected: the dictation goes on and is inserted on release.

### M-INS-1: TextEdit
1. Type "Please" in a TextEdit document, leave the cursor right after it, then hold fn and say "Send the report today."
2. Expected: "Please send the report today." The text starts with a space and a lowercase "send".

### M-INS-2: Slack
1. Click into a Slack message box (desktop app). Hold fn, say a sentence, then release.
2. Expected: the sentence appears in the box and is not sent. The clipboard is restored.

### M-INS-3: browser
1. Click into a text field in Safari or Chrome (for example a GitHub comment box). Hold fn, say a sentence, then release.
2. Expected: the sentence appears in the field.

### M-INS-4: paste that does not land
1. Open Activity Monitor and click its process list, so no text field has focus. Hold fn, say a sentence, then release.
2. Expected: a yellow ring and "Paste did not land. The text is in Recent." Clicking the entry in Recent copies the text.

### M-NS-1: no speech
1. Copy a word in TextEdit (Cmd+C), then click into the document. In a quiet room, hold fn for about 2 s without speaking, then release.
2. Expected: nothing is inserted. A yellow ring and "No speech heard" show for about 4 s. Cmd+V still pastes the word you copied.
3. Expected: Recent in the 🤫 menu has a "(no speech)" entry, and a new WAV is in Open recordings folder.
4. Hold fn, say only "um, uh", then release. Expected: the same as steps 2 and 3.
5. Hold fn and say a quiet "yes" from about an arm's length away. Expected: "yes" is inserted. If it shows "No speech heard" instead, or room noise in step 1 got transcribed, the -60 dBFS floor does not fit this mic: note the mic and the room in #15. You can try another floor with `defaults write io.backant.shepetal speechFloorDb -float -65` and relaunch.

### M-RET-1: delete after 24 hours
1. In the 🤫 menu choose Recordings > Delete recordings after 24 hours.
2. Expected: recordings older than 24 h are gone from the recordings folder right away. Newer ones stay. (The timing itself is covered by `StorageTests.testRetention24hDeletesOnTime`.)

### M-INS-5: space before the following word (F109)
1. In TextEdit type "Hello world", then put the cursor right before "world". Hold fn, say "big", then release.
2. Expected: "Hello big world", with one space on each side of "big".
3. Select "big world" and press Cmd+C. In Terminal run `pbpaste | xxd | head -2`. Expected: `c2 a0` (a non-breaking space) right after "big", not `20`.

### M-INS-6: replace a selection (F109)
1. In TextEdit type "Send the draft today." Double-click "draft". Hold fn, say "Final version.", then release.
2. Expected: "Send the final version today." The new words are lowercase like "draft", and there is no period after them.
3. Select "today." including its period. Hold fn and say "Tomorrow". Expected: "Send the final version tomorrow." with the period kept.
4. Select " version " with the spaces on both sides. Say "copy". Expected: "Send the final copy tomorrow." with no double or missing spaces.

### M-FOC-1: text only goes into the window that stayed in focus (F27, rule 8)
1. Open a TextEdit document and Notes. Copy a word, say "earlier", from anywhere. Click into the TextEdit document. Double-tap fn and say a sentence.
2. Click into a Notes note, then tap fn once to stop.
3. Expected: Notes stays in front and focused; TextEdit does not come back. Neither TextEdit nor Notes gets any text. "The window changed while you spoke. The text is on the clipboard: press ⌘V to paste it." shows next to 🤫.
4. Press ⌘V in the Notes note. Expected: the sentence is pasted. Recent has it too, and "earlier" is not put back on the clipboard.
5. Click into the TextEdit document. Double-tap fn, say a sentence, click into a different line of the same document, and tap fn to stop. Expected: the sentence lands at the new cursor position, because the window did not change.
6. Repeat step 5, but open a second TextEdit document (Cmd+N) before tapping fn. Expected: as in step 3, nothing is pasted and the text is on the clipboard.

### M-SEC-1: Secure Input (F17)
1. Open Terminal and turn on Terminal > Secure Keyboard Entry. Keep Terminal in front for about 3 s.
2. Expected: "Secure input is on in Terminal, so fn can't be heard" shows next to 🤫 once. It does not come back every 2 s.
3. Still in Terminal, hold fn, speak, then release. Expected: either nothing records (macOS hides fn from Shepetal), or "Secure input is on in Terminal. The text is on the clipboard: press ⌘V to paste it." shows and nothing is pasted. Press ⌘V: the text is pasted into Terminal. Recent has the text too. Write down which one happened.
4. Click into another app, so Terminal no longer holds secure input. Expected: the note is gone if it was still showing. Click back into Terminal. Expected: the note shows once more.
5. Turn Secure Keyboard Entry off again.

### M-PERM-5: a permission turned off while Shepetal runs (F90)
1. Start Shepetal with all three permissions ✅. Open System Settings > Privacy & Security > Accessibility and turn Shepetal off.
2. Expected: within 2 s, a yellow ring and "Accessibility access was turned off" next to 🤫, and the Permissions window opens with Accessibility ⚠️. The message shows once, not every 2 s.
3. Turn Shepetal back on. Expected: the yellow ring clears within 2 s. Turn it off again. Expected: the message shows again.
4. Repeat steps 1 to 3 with Microphone and with Input Monitoring. After turning Input Monitoring back on, hold fn in TextEdit and speak. Expected: it records and inserts. If fn does nothing until Shepetal restarts, note it on #32.
5. Quit Shepetal, run `open dist/Shepetal.app --args --no-permission-prompts`, and turn Accessibility off. Expected: the message and the yellow ring show, but no window opens.

### M-LOGIN-1: Start at login (F92)
1. Open the 🤫 menu and choose Start at login.
2. Expected: the item is checked. If macOS wants approval instead, "Allow Shepetal in System Settings > General > Login Items" shows next to 🤫 and System Settings opens at Login Items. Allow Shepetal there. The item is then checked the next time you open the menu.
3. Log out and log back in. Expected: 🤫 is in the bottom-left corner and in the menu bar without you opening Shepetal, and there is no Dock icon.
4. Choose Start at login again. Expected: unchecked, and Shepetal is gone from Login Items. The installer turns it on; builds signed with the same certificate keep it.

### M-SND-1: sounds (F06)
1. Turn the volume up. Hold fn, speak, and release. Expected: a short rising blip about half a second after the ring turns red, and a short falling blip on release. Neither is loud.
2. Double-tap fn. Expected: a quick double blip when the ring turns orange. Tap fn to stop: the falling blip.
3. Press fn+Delete quickly. Expected: no sound. Tap fn briefly once. Expected: no sound, only the hint. Hold fn until the rising blip, then press Delete within the first second. Expected: the rising blip, then a low tone.
4. Play the newest WAV in Open recordings folder. The start blip may be faint about half a second in. Expected: the transcript in Recent has no extra word from it.
5. Uncheck Sounds in the 🤫 menu. Expected: steps 1 to 3 make no sound. Quit and reopen Shepetal: Sounds is still unchecked.

### M-HUB-1: open the Shepetal window
1. Before you install this build, run `sqlite3 ~/Library/Application\ Support/Shepetal/history.sqlite 'select count(*) from history'` and note the number. Install and open the new build. Run the command again. Expected: the same number. (`HistoryTests.testOldDatabaseUpgradesWithoutLosingRows` checks this on a copy of the old schema.)
2. With all three permissions granted, quit Shepetal and open it again from Finder or Spotlight. Expected: only 🤫 appears. No Shepetal window opens.
3. Open the 🤫 menu and choose Open Shepetal…. Expected: a window titled "Shepetal" with Home, History and Settings tabs comes to the front.
4. Close it. Open `dist/Shepetal.app` again (Finder, Spotlight or `open dist/Shepetal.app`). Expected: the same window opens. No second 🤫 appears.
5. Home: expected rows for the speech model, the fn key ("Watched…" once Input Monitoring is on), and the missing permissions with Open Permissions…. Each Donate link opens its page in the browser.

### M-HUB-2: search and copy
1. Dictate "Send the quarterly report today" and then "Call the dentist at 100% volume" into TextEdit (M-FN-1). Open History.
2. Type `QUARTERLY` in Search. Expected: only the first dictation is listed. Type `100%`. Expected: only the second. Clear the field. Expected: both, newest first.
3. Click Copy on the first, then Cmd+V in TextEdit. Expected: its text.

### M-HUB-3: play, and recordings that are gone
1. Click Play on a dictation. Expected: you hear that recording.
2. In the recordings folder (Settings > Open recordings folder), run `touch -t 202001010000 <file>.wav` on one recording, then choose Settings > Recordings > Delete recordings after 24 hours.
3. Expected: that row now says "recording deleted", its Play and Re-transcribe are greyed out, and its text and Copy still work. Set Recordings back to Keep recordings if you want.

### M-HUB-4: re-transcribe
1. Click Re-transcribe on a dictation and choose the entry marked "(current)". Expected: "Re-transcribed with parakeet-tdt-0.6b-v3" under the list. The row keeps its time, outcome and app.
2. Install the whisper.cpp fallback (README, Mac). Choose the other model in the same menu. Expected: after a few seconds, "Re-transcribed with ggml-…", and the row's text is the whisper result. Without the fallback installed, expected: "Re-transcribe failed: … not found", and the row is unchanged.

### M-HUB-5: archive
1. Click Archive on a dictation. Expected: it leaves the list.
2. Tick Show archived. Expected: it is back, marked "archived", with Unarchive. Click Unarchive and untick Show archived. Expected: it stays in the list.

### M-HUB-6: settings
1. In Settings, set Recordings to Delete recordings after 24 hours. Expected: the 🤫 menu's Recordings submenu shows the same choice.
2. Open recordings folder opens Finder at the audio folder. Permissions… opens the Permissions window.

### M-CTX-1: app and page URL
1. Dictate into TextEdit, into a text field in Safari, and into a text field in Chrome (for example a GitHub comment box).
2. Open History. Expected: the rows show "TextEdit", "Safari · github.com" and "Google Chrome · github.com". The URL is stored only in `history.sqlite` (`sqlite3 … 'select app, bundle_id, url from history order by created_at desc limit 3'`).
3. If a Chrome row has no host, note it on the PR: Chrome had no accessibility tree for the page (see the `ponytail:` note in `Sources/Shepetal/AppContext.swift`).
4. With Chrome in front on a heavy page (a long GitHub pull request), tap fn quickly five times, waiting 2 s after each tap. Expected: each tap shows the short-press hint and nothing is inserted. The page-URL lookup runs off the main thread, so a slow page must not turn a tap into a hold.

## iPhone

Setup (I-SETUP-1 below). The simulator has no usable mic path for this flow, so every step runs on a real iPhone with iOS 17 or later. Steps that look into the app's files use Xcode > Window > Devices and Simulators > your iPhone > Installed Apps > Shepetal > ⋯ > Download Container. In the downloaded container (Show Package Contents), the recordings are in `AppData/Library/Application Support/audio/`.

### I-SETUP-1: install
1. `cd ios && xcodegen generate`, then open `Shepetal.xcodeproj`.
2. Set your team on the `Shepetal`, `ShepetalKeyboard` and `ShepetalWidget` targets. Give `Shepetal` and `ShepetalKeyboard` the App Group `group.io.backant.shepetal`. If your team cannot register that id, change it in `project.yml` and `Core/Handoff.swift` (`SharedHandoff.appGroup`).
3. Run the `Shepetal` scheme on the iPhone.
4. Expected: the app shows "Loading speech model..." and then "Ready. Tap the mic on the Shepetal keyboard." The first launch downloads the model, which takes a few minutes. Later launches load it from the iPhone.

### I-KB-1: enable the keyboard
1. Settings > General > Keyboard > Keyboards > Add New Keyboard... > Shepetal.
2. Open Notes, tap into a note, and hold the globe key. Pick Shepetal.
3. Expected: a mic button, a delete key and a small 🤫 in the bottom-left corner of the keyboard, about 8 pt from its left and bottom edges, with no ring around it.

### I-KB-2: Full Access
1. With Full Access off (Settings > General > Keyboard > Keyboards > Shepetal > Allow Full Access off), tap the mic on the Shepetal keyboard.
2. Expected: a yellow ring around 🤫 and "Turn on Allow Full Access for Shepetal in Settings." next to it. Shepetal does not open.
3. Turn on Allow Full Access. The keyboard needs it to reach the App Group it shares with the app; it makes no network calls.
4. Expected: the next tap on the mic opens Shepetal (I-MIC-1).

### I-MIC-1: microphone permission
1. Start from a fresh install. Deleting the app and running it again from Xcode resets the permission, and also removes the model and the recordings.
2. In Notes, tap the mic on the Shepetal keyboard. Shepetal opens and iOS asks for the microphone. Tap Don't Allow.
3. Expected: the app says "Microphone access denied. Enable it in Settings > Shepetal." Go back to Notes: the keyboard shows a yellow ring and "Microphone access is off. Turn it on in Settings > Shepetal."
4. Turn the microphone on in Settings > Shepetal and repeat step 2. Expected: the app says "Listening. Go back to your app and tap the mic to finish." and the orange mic dot shows in the status bar.

### I-DICT-1: dictation round trip
1. In a note, tap the mic. The keyboard shows a blue ring and "Opening Shepetal...", and Shepetal opens with "Listening...".
2. Go back to Notes with the back control in the top-left corner of the status bar. Expected: the keyboard shows a red ring and "Listening. Tap the mic to finish."
3. Say "Testing one two three, this is a dictation check." Tap the mic.
4. Expected: a blue ring and "Transcribing...", then the sentence appears at the cursor and the ring goes away. Shepetal's history lists the recording as `transcribed` with the same text, and the container has `audio/<id>.wav` and `audio/<id>.json`.
5. Turn on Airplane Mode and repeat steps 1 to 4. Expected: the same result. Nothing needs the network.

### I-IND-1: the 🤫 indicator and its colors
1. Keep the Shepetal keyboard up during I-DICT-1, I-SHORT-1 and I-CANCEL-1.
2. Expected: 🤫 is always in the bottom-left corner of the keyboard, about 18 pt, and tapping it does nothing. Its ring uses the Mac colors: red while recording, blue while Shepetal opens or transcribes, yellow for an error, none when idle. The state text sits right of it and never covers the mic or delete key.

### I-LA-1: Live Activity and Dynamic Island
The Dynamic Island steps need an iPhone 14 Pro or later (any iPhone 15, 16 or 17). On other iPhones, run only the lock screen steps (3, 7, 8).
1. Start a dictation (I-DICT-1 steps 1 and 2).
2. Expected: once you are back in Notes, the Dynamic Island shows 🤫 with a red ring on the left and "Listening" on the right. Touch and hold the island: the expanded view shows the same.
3. Lock the iPhone. Expected: the lock screen shows the Live Activity with 🤫, a red ring and "Listening". Unlock and go back to Notes.
4. Tap the mic on the keyboard. Expected: the island shows a blue ring and "Transcribing", then the Live Activity ends when the text is inserted.
5. Start a Timer in the Clock app, then start a dictation. With two Live Activities, iOS shows one of them as a small circle at the edge of the island. Expected: when that circle is Shepetal's, it shows 🤫 with its ring.
6. Tap the mic and stop it at once (I-SHORT-1). Expected: the island shows a yellow ring and "Not inserted" for about 4 s, then the Live Activity ends.
7. Turn off Settings > Shepetal > Live Activities and run I-DICT-1 again. Expected: no Live Activity, and dictation works the same.
8. Start a dictation, go back, then force-quit Shepetal from the app switcher. Lock the iPhone. Expected: the Live Activity stays at most about 6 minutes on "Listening" with a red ring, then shows "Stopped" without a ring. Opening Shepetal removes it.

### I-CAP-1: 5-minute cap
1. Start a dictation, go back to Notes and leave it running. Talk now and then.
2. Expected: after 5 minutes the orange mic dot goes off without a tap, the text arrives in the note, and "Stopped at the 5-minute limit." shows next to 🤫. History lists the recording with that note, and its `audio/<id>.wav` holds the full 5 minutes.

### I-CANCEL-1: cancel keeps the audio
1. Start a dictation, say a sentence, then switch to Shepetal and tap Cancel.
2. Expected: the app says "Cancelled. The recording is kept." Back in Notes, nothing is inserted and the keyboard says "Cancelled. Shepetal kept the audio."
3. Download the container. Expected: `audio/<id>.wav` holds the sentence and `audio/<id>.json` has `"outcome":"cancelled"`. History lists it as `cancelled`.

### I-FIELD-1: a result for a different field goes to the clipboard
1. Copy a word from anywhere, so the clipboard holds something you recognize.
2. In note A, start a dictation, go back and say a sentence.
3. Without stopping, open note B (or a text field in another app), bring up the Shepetal keyboard there and tap the mic. This stops the recording.
4. Expected: nothing is inserted into note B. "You are in a different field now, so the text is on the clipboard. Tap the field and choose Paste." shows next to 🤫, with no ring. Shepetal's history lists the recording with its text.
5. Tap note B and choose Paste. Expected: the sentence is pasted as plain text, and the word from step 1 is gone from the clipboard. Go back to note A: nothing is inserted there either.
6. With a Mac signed in to the same Apple Account and Handoff on, press ⌘V in a Mac text field. Expected: the sentence does not arrive (the copy is local to the iPhone).

### I-SHORT-1: too short
1. Tap the mic, go back, and tap the mic again right away (under 0.3 s of audio).
2. Expected: nothing is inserted. A yellow ring and "Too short to transcribe. Tap the mic, speak, then tap it again." show next to 🤫. History lists the recording as `tooShort`, and its `audio/<id>.wav` is in the container.

### I-INT-1: interruptions
1. Start a dictation, go back, and say a sentence. Then ask Siri something, or take a call.
2. Expected: the recording stops. What you said before is inserted, with "Recording stopped early: ..." next to 🤫.
3. Repeat, but connect AirPods during the recording instead. Expected: the same.

### I-URL-1: requests from other apps
1. In Safari, open `shepetal://dictate?id=00000000-0000-0000-0000-000000000000` and allow it to open Shepetal.
2. Expected: the app says "Ignored a dictation request that did not come from the Shepetal keyboard.", no microphone prompt shows, and the orange mic dot stays off.

### I-EXP-1: stale request
1. Start from a fresh install (see I-MIC-1). Tap the mic in Notes. When iOS asks for the microphone, wait more than 60 s, then tap Allow.
2. Expected: no recording starts, and the orange mic dot stays off. Go back to Notes: the keyboard shows a yellow ring and "That dictation timed out. If it was transcribed, the text is in Shepetal's history." Nothing is inserted.

### I-LOCK-1: recording that ends while the iPhone is locked
1. Start a dictation, go back, and lock the iPhone. Wait past the 5-minute cap. The audio cannot be written while the iPhone is locked, so the app holds it in memory.
2. Unlock and open Shepetal. Expected: the recording is in the history, and `audio/<id>.wav` and its `.json` are in the container. A red "recording(s) not saved yet" line may show for a moment and must then go away.

### I-BACKUP-1: audio stays off backups
1. With iCloud Backup on, open Settings > [your name] > iCloud > Manage Account Storage > Backups > this iPhone and look at Shepetal.
2. Expected: the recordings do not count toward its size.
3. In a downloaded container, run `xattr -l "AppData/Library/Application Support/audio"`. Expected: `com.apple.metadata:com_apple_backup_excludeItem` is listed. If the download dropped all extended attributes, write that down; step 2 is the check that counts.

### I-RET-1: delete after 24 hours
1. Make a recording. In Shepetal, turn on "Delete recordings after 24 h".
2. Come back more than 24 h later and open Shepetal.
3. Expected: recordings older than 24 h are gone from the history and the container, and newer ones stay. Deletion only runs when the app opens or comes to the front (see `ios/README.md`, "Not done yet").

### I-DONATE-1: Donate links
1. In Shepetal, tap "Donate: Buy Me a Coffee", then "GitHub Sponsors".
2. Expected: they open https://buymeacoffee.com/sorcecoder and https://github.com/sponsors/backant-io.

### I-DOCID-1: field identity survives a keyboard relaunch
1. Start a dictation in a note and go back. Before stopping, switch to the system keyboard with the globe key and back to Shepetal, in the same note.
2. Tap the mic. Expected: the text is inserted. If you see "You are in a different field now, so the text is on the clipboard" instead, the keyboard is given a new `documentIdentifier` after a relaunch, and every such result goes to the clipboard instead of the field. Report it.

## Meetings

The Mac `meeting/` CLI on its own. The Mac app does not use it yet (#16). Build it with `cd meeting && swift build`, and run the commands from `meeting/`. Expected output lines are quoted as the CLI prints them.

### MEET-1: probe
1. Quit every app that uses the mic. Run `.build/debug/shepetal-meeting probe`.
2. Expected: `no process is using the mic` and `meeting apps now: []`. It needs no permission. `calendar event now:` names the event in progress if your terminal app has Calendar access, otherwise `none (or no Calendar access)`. The CLI never asks for Calendar access.
3. Join a Zoom call and run `probe` again. Expected: a line whose bundle id starts with `us.zoom.xos`, and `meeting apps now: ["Zoom"]`.

### MEET-2: watch a Zoom call
1. Run `START_AFTER=2 END_AFTER=3 .build/debug/shepetal-meeting watch` (the defaults are 5 s and 30 s).
2. Join a real Zoom call, or a test call at https://zoom.us/test. Expected: about 2 s after Zoom takes the mic, `started(app: "Zoom")`.
3. During the call, switch your default mic or output, for example to AirPods. Expected: no event.
4. Stay in the call for at least 15 s (no meeting ends sooner), then leave it. Expected: about 4 s later, `ended(app: "Zoom")`.

### MEET-3: watch a Google Meet call
1. Browser meetings are found by window title, which macOS shows only to apps with Screen Recording access. Turn it on for your terminal app in System Settings > Privacy & Security > Screen & System Audio Recording, then restart the terminal. Without it, browser meetings are not found.
2. Run `watch` as in MEET-2 and join a Google Meet call in Chrome. Expected: `started(app: "Google Meet (Chrome)")`.
3. Switch to another tab for a minute and back. Expected: no event.
4. Close the Meet tab. Expected: about 4 s later, an `ended` line for the same app.

### MEET-4: shepetal's own dictation does not count
1. Set up a calendar event that runs now, as in MEET-5, so any other app holding the mic would count. Start `watch` with no call.
2. Dictate with the shepetal Mac app for about 10 s.
3. Expected: no event.

### MEET-5: calendar meeting
1. Give your terminal app Calendar full access. Create a calendar event that runs now.
2. With `watch` running, start a mic app that is not a meeting app, for example QuickTime Player > File > New Audio Recording.
3. Expected: after the start delay, `started(app: "QuickTime Player: <event title>")`.

### MEET-6: record a call
1. During a real Zoom or Meet call where someone else talks, run `.build/debug/shepetal-meeting record 15`.
2. The first run, macOS asks for microphone and "System Audio Recording Only" access for your terminal. Allow both and run it again.
3. Expected: `saved /Users/<you>/Library/Application Support/shepetal/meetings/<time>/Me.wav and Others.wav` and exit code 0. On failure it prints `record failed: <reason>` and exits 1.
4. Play both files. Expected: `Me.wav` holds your voice, `Others.wav` the other people in the call.
5. Run `ls -la` on the meeting folder and its parent. Expected: `drwx------` on the folder, `-rw-------` on both files.
