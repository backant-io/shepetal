# Manual tests

Steps a person has to run: they need physical keys, a voice, or a permission grant. Automated checks are not repeated here.

## Mac

Setup: install the app once, either from the release zip (README > Mac > Install) or with `scripts/make-app.sh --install`, which builds it and installs it to `/Applications/Shepetal.app`. Open it from Finder or with `open /Applications/Shepetal.app`. If the 🌐/fn key opens the emoji picker or starts macOS Dictation, set System Settings > Keyboard > "Press 🌐 key to" to "Do Nothing". If Wispr Flow is running with fn as its shortcut, both apps hear fn and both insert text: quit Wispr Flow (or move its shortcut off fn) before testing Shepetal.

The app is signed with a certificate when the build machine has one (`scripts/make-app.sh` prints "Signed with: …"). Then macOS keeps the permissions across rebuilds and updates. If it prints "Signed ad-hoc", every rebuild counts as a new app for macOS and the permissions have to be granted again. To run the M-PERM tests from scratch, quit Shepetal and reset its grants with `tccutil reset All io.backant.shepetal`.

### M-SETUP-1: first run from the release zip
1. Download the zip from the release, double-click it, and drag `Shepetal.app` into Applications.
2. Double-click `Shepetal.app`. If macOS blocks it, use System Settings > Privacy & Security > Open Anyway (README > Mac > Install, step 3).
3. Expected: no Dock icon appears. 🤫 appears in the menu bar and, tiny, in the bottom-left corner of the screen. The Permissions window opens.
4. Grant Microphone, Input Monitoring and Accessibility. Expected: each row turns ✅ and the 🤫 menu's first line reads "Hold fn to talk, double-tap for hands-free".
5. Click into any text field, hold fn, say a sentence, release. Expected: the sentence is typed there.

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

### M-LOGIN-1: Open at login (F92)
1. Open the 🤫 menu and choose Open at login.
2. Expected: the item is checked. If macOS wants approval instead, "Allow Shepetal in System Settings > General > Login Items" shows next to 🤫 and System Settings opens at Login Items. Allow Shepetal there. The item is then checked the next time you open the menu.
3. Log out and log back in. Expected: 🤫 is in the bottom-left corner and in the menu bar without you opening Shepetal, and there is no Dock icon.
4. Choose Open at login again. Expected: unchecked, and Shepetal is gone from Login Items. Every `scripts/make-app.sh` build has a new ad-hoc signature, so turn it off and on again after a rebuild.

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
