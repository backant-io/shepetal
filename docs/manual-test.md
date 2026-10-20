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
