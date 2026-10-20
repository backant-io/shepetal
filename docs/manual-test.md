# Manual tests

Steps a person has to run: they need physical keys, a voice, or a permission grant. Automated checks are not repeated here.

## Mac

Setup: `scripts/make-app.sh`, then `open dist/Shepetal.app`. The app is ad-hoc signed, so every rebuild counts as a new app for macOS and the permissions have to be granted again. If the 🌐/fn key opens the emoji picker or starts macOS Dictation, set System Settings > Keyboard > "Press 🌐 key to" to "Do Nothing".

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

### M-ESC-1: Esc cancels and keeps the audio
1. In TextEdit choose File > Open… so a dialog is open. Hold fn, say a sentence, and press Esc while still holding fn. Release fn.
2. Expected: nothing is inserted, the ring goes away, and "Cancelled" shows next to 🤫 for about 2 s. The Open dialog is still open, because Shepetal kept that Esc from the app (with Accessibility on).
3. Double-tap fn for hands-free, say a sentence, press Esc. Expected: the same.
4. With nothing recording, press Esc. Expected: the Open dialog closes, because an idle Esc reaches the app.
5. Expected: Recent in the 🤫 menu has a "(cancelled)" entry for steps 1 and 3, and each has a WAV in Open recordings folder.

### M-ESC-2: Esc while transcribing
1. Double-tap fn in TextEdit and talk for about a minute (a longer recording takes longer to transcribe). Tap fn and press Esc right after it, while the ring pulses blue.
2. Expected: nothing is inserted and "Cancelled" shows. Recent has the entry with its text, marked cancelled in `history.sqlite` (`sqlite3 ~/Library/Application\ Support/Shepetal/history.sqlite "select outcome, text from history order by created_at desc limit 1"`). If the text was already inserted, Esc came too late. Try again with a longer recording.

### M-KEY-1: fn+Space hands-free toggle
1. In TextEdit, with nothing recording, press fn+Space (fn first) and release both. Expected: the ring turns orange and stays. No space character is typed.
2. Speak a sentence, then press fn+Space again. Expected: the text is inserted, again without an extra space.
3. Press fn+Space, then press it again within half a second. Expected: the recording is thrown away. Nothing is inserted, and Recent has a "(cancelled)" entry.

### M-KEY-2: hold fn, then add Space
1. In TextEdit hold fn and start speaking. Still holding fn, press Space, then release both.
2. Expected: the ring turns from red to orange and recording goes on. No space is typed.
3. Tap fn once. Expected: the whole dictation is inserted.

### M-KEY-3: Shortcuts window
1. In the 🤫 menu choose Shortcuts…. Expected: hold to talk fn, hands-free fn Space, cancel Esc, paste last ⌃ ⌘ V, copy last ⌃ ⌘ C.
2. Click Change… next to Paste last text and press ⌘Tab. Expected: "⌘ Tab: macOS or most apps already use these keys." and the chord stays ⌃ ⌘ V.
3. Click Change… again and press A alone, then ⌘ with both Command keys plus A, then fn. Expected, in turn: "Add fn, ⌃, ⌥, ⇧, ⌘ or a mouse button.", "Use one side of a modifier, not both.", "Another action already uses these keys."
4. Click Change… and press ⌃⌥P. Expected: the row shows ⌃ ⌥ P. Quit and reopen Shepetal. Expected: still ⌃ ⌥ P, and ⌃⌥P now pastes the last text.
5. With a mouse that has side buttons: Change… for Hold to talk, press mouse button 4. Expected: "Mouse 4". Holding it records, releasing inserts, and the browser does not go back a page.
6. Click Reset to defaults. Expected: the defaults from step 1.
7. Turn Accessibility off for Shepetal and reopen the window. Expected: the note says that Esc and the keys of a shortcut also reach the app. Turn it back on.

### M-LEN-1: maximum length
1. Run `defaults write io.backant.shepetal maxDictationMinutes -int 2` and restart Shepetal.
2. In TextEdit double-tap fn and keep talking (or let it run).
3. Expected: after 1 minute "1 minute left" shows next to 🤫. After 2 minutes the recording stops by itself and the text is inserted as if you had tapped fn.
4. Run `defaults delete io.backant.shepetal maxDictationMinutes` and restart. The cap is back to 20 minutes, with the warning at 19.

### M-LAST-1: paste last and copy last
1. Open Activity Monitor and click its process list. Hold fn, say a sentence, release (the paste does not land, as in M-INS-4).
2. Click into a TextEdit document and press ⌃⌘V. Expected: the sentence is inserted, and no "v" is typed.
3. Copy some other text with ⌘C, then press ⌃⌘C and paste with ⌘V. Expected: the sentence again.
4. Tap fn once briefly (too short) and wait for the hint to go away, then press ⌃⌘V. Expected: still the same sentence, because entries without text are skipped.
5. The 🤫 menu's "Paste last text" and "Copy last text" do the same.

### M-MIC-1: choosing the mic
1. Plug in a USB or Bluetooth mic you have never used with Shepetal. Expected: "New mic: <its name>" shows next to 🤫. Unplug and plug it in again: nothing shows.
2. Open 🤫 > Microphone. Expected: "Automatic (<mic in use>)" is checked, every input device is listed, and a "Prefer <name>" item is listed for each.
3. Choose the USB mic's name (this forces it). Dictate a sentence while tapping the USB mic, then play the newest WAV from Open recordings folder. Expected: the tap is loud, so the USB mic recorded.
4. Choose Automatic, then "Prefer <USB mic>". Dictate again. Expected: the USB mic records. Unplug it. Expected: "Using <next mic>" shows next to 🤫, and the next dictation works.

### M-MIC-2: closed lid
1. On a MacBook with an external display, keyboard and a USB mic, close the lid. Dictate. Expected: the USB mic records, even when MacBook Pro Microphone is forced or ranked first (the menu shows it as "(lid closed)" and greyed out).
2. Unplug the USB mic and dictate. Expected: no recording starts, and a yellow ring with "The lid is closed and no other mic is connected. Open the lid or plug in a mic."

### M-MIC-3: mic disconnected mid-dictation
1. Force a USB or Bluetooth mic. Double-tap fn for hands-free, say a sentence, then unplug the mic (or switch off the headset) while still recording.
2. Expected: recording stops, "Mic disconnected" shows next to 🤫, what you said before the unplug is inserted, and its WAV is in Open recordings folder.

### M-MIC-4: dead mic
1. Force an input that sends only silence: a loopback driver with nothing playing (for example Microsoft Teams Audio when Teams is closed, or BlackHole). Double-tap fn for hands-free and wait.
2. Expected: after about 5 s "No sound from <name>. Is it muted?", and after about 15 s "Still no sound from <name>. Pick another mic in the 🤫 menu." Tap fn: the WAV is kept and holds silence.

### M-MIC-5: Bluetooth and quiet recordings
1. With AirPods connected and preferred, dictate once. Expected: "Tip: the built-in mic records clearer than Bluetooth" shows once. Dictate again: it does not show again, not even after a relaunch.
2. On the built-in mic, hold fn and say a sentence very quietly from about an arm's length away. Expected: after the text lands, "Speak closer or use a wired mic". A normal sentence at normal distance does not show it. If it shows too often or never, tune it with `defaults write io.backant.shepetal micQuietFloor -float 0.002` (RMS, default 0.003) and relaunch.

### M-LANG-1: languages
1. Open 🤫 > Languages. Expected: Automatic is checked; the list holds whisper's languages with their names.
2. Check Deutsch and Français. Expected: the menu's model line stays "Model: parakeet-tdt-0.6b-v3" (no reload). Say a German sentence. Expected: German text.
3. Check 日本語 (Japanese). Expected: the model line reads "Model: ggml-large-v3-turbo-q5_0" when that model and `whisper-cli` are in `~/Library/Application Support/Shepetal/models/`. Otherwise it says which file is missing and where it goes, and dictation shows "Speech model is not loaded" until you install it or choose Automatic.
4. Choose Automatic. Expected: the model line goes back to Parakeet.

### M-DICT-1: personal dictionary
1. Choose 🤫 > Dictionary…. Expected: `dictionary.txt` opens in your default text editor, holding only comment lines that explain the format. `ls -l ~/Library/Application\ Support/Shepetal/dictionary.txt` shows `-rw-------`.
2. Add the lines `GitHub` and `asap => as soon as possible`, save, and without restarting Shepetal dictate "push it to github asap".
3. Expected: "Push it to GitHub as soon as possible." A word that only contains "asap" (for example "asaps") is left alone.
