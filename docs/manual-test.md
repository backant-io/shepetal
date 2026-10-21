# Manual tests

Steps a person has to run: they need physical keys, a voice, or a permission grant. Automated checks are not repeated here.

## Mac

Setup: install the app once, either from the release DMG (README > Mac > Install) or with `scripts/make-app.sh --install`, which builds it and installs it to `/Applications/Shepetal.app`. Open it from Finder or with `open /Applications/Shepetal.app`. If the 🌐/fn key opens the emoji picker or starts macOS Dictation, set System Settings > Keyboard > "Press 🌐 key to" to "Do Nothing". If Wispr Flow is running with fn as its shortcut, both apps hear fn and both insert text: quit Wispr Flow (or move its shortcut off fn) before testing Shepetal.

The app is signed with a certificate when the build machine has one (`scripts/make-app.sh` prints "Signed with: …"). Then macOS keeps the permissions across rebuilds and updates. If it prints "Signed ad-hoc", every rebuild counts as a new app for macOS and the permissions have to be granted again. To run the M-PERM tests from scratch, quit Shepetal and reset its grants with `tccutil reset All io.backant.shepetal`.

### M-DMG-1: the DMG
1. Download `Shepetal-<version>.dmg` from the release in Safari and open it.
2. Expected: no Gatekeeper warning beyond "downloaded from the internet" (a notarized release; a dry-run or unnotarized DMG is refused by macOS 15 until Privacy & Security › Open Anyway). The window shows Shepetal.app on the left, Applications on the right, the curved arrow between them, "shepetal" at the top and "Drag Shepetal into Applications" under the icons, with no toolbar or sidebar. Check that the icon labels read well in both Light and Dark appearance (System Settings › Appearance).
3. Drag Shepetal into Applications. Expected: it copies; the volume icon on the desktop is 🤫.

### M-MOVE-1: moving itself to Applications
1. Remove /Applications/Shepetal.app (to the Trash), open the DMG, and open Shepetal from the DMG window.
2. Expected: "Move Shepetal to Applications?" with Move to Applications (default) and Not Now. Click Move. Expected: Shepetal quits and opens again from /Applications (`ps -o comm= -p $(pgrep -x Shepetal)` shows /Applications/Shepetal.app), and the permissions granted to the DMG copy are kept.
3. Open the DMG copy again. Expected: no question this time (asked once).
4. With a NEWER build in /Applications, open an older DMG's copy and click Move. Expected: the newer copy opens and nothing is replaced.

### M-MOVE-2: asked once per version, ~/Applications, no downgrade (F124)
1. Choose Quit shepetal. Move /Applications/Shepetal.app to the Trash. Download the release zip `Shepetal-<version>-mac.zip` in Safari, so it lands in ~/Downloads with the quarantine flag, and unzip it there by double-clicking it.
2. Open ~/Downloads/Shepetal.app from Finder. Expected: "Move Shepetal to Applications?" with Move to Applications and Not Now. Click **Not Now**. Expected: shepetal keeps starting (onboarding or the 🤫 menu) and works from Downloads.
3. Quit shepetal and open the same copy again. Expected: no question (Not Now is remembered for this build).
4. Run `defaults delete io.backant.shepetal movePromptVersion`, then open the Downloads copy again and click **Move to Applications**. Expected: shepetal quits and opens again from /Applications (`ps -o comm= -p $(pgrep -x Shepetal)` shows /Applications/Shepetal.app/…), ~/Downloads/Shepetal.app is in the Trash, and the macOS permission prompts (or System Settings › Privacy & Security) name the copy in /Applications.
5. Optional, the root-owned copy the old .pkg left: `sudo chown -R root:wheel /Applications/Shepetal.app`, unzip the release zip in ~/Downloads again, run `defaults delete io.backant.shepetal movePromptVersion`, open the Downloads copy and click Move. Expected: it moves to ~/Applications/Shepetal.app and opens from there, and an alert says "shepetal is now in your own Applications folder" and that the copy in /Applications must go to the Trash in Finder. Reset: quit shepetal, move ~/Applications/Shepetal.app to the Trash and run `sudo chown -R $USER:staff /Applications/Shepetal.app`.
6. Optional, no downgrade: with the newest build in /Applications, unzip an older release zip in ~/Downloads, run `defaults delete io.backant.shepetal movePromptVersion`, open the Downloads copy and click Move. Expected: the /Applications copy opens (`defaults read /Applications/Shepetal.app/Contents/Info CFBundleVersion` is the newer build, and `ps -o comm= -p $(pgrep -x Shepetal)` shows /Applications/Shepetal.app/…), nothing appears in ~/Applications, and ~/Downloads/Shepetal.app stays.

### M-ONB-1: first-run onboarding
1. On a fresh macOS user account (or after `tccutil reset All io.backant.shepetal` and `defaults delete io.backant.shepetal onboardingDone`), open Shepetal.
2. Expected: the "Welcome to Shepetal" window. Microphone, Accessibility and Input Monitoring each show ⚠️ with an Open button, and System Audio Recording (optional) too. Continue is disabled.
3. Click each Open. Expected: the first click asks macOS (the Microphone prompt), then System Settings opens the matching pane. Grant each one: within a second its row turns ✅. Once the three required rows are ✅, Continue is enabled, whatever System Audio says.
4. Release build (sign-in required) and signed out: Expected: the next step is the Account section with Sign in with Google; Continue is enabled once signed in. A build from source skips this step.
5. Try it: click the field, hold fn, say a sentence, release. Expected: the sentence lands in the field and "✅ It works" shows. While the speech model is not ready, the field is disabled and the engine line says why.
6. "Start Shepetal when I log in" is ticked. Close the window with the red button instead of Done. Expected: no login item (System Settings › General › Login Items), and the window does NOT open again at the next launch (closed counts as seen, so it never takes the focus at every login). Turn off one required permission and open Shepetal: it opens again.
7. Open Shepetal again, go through to Done. Expected: the window closes, Settings shows Start at login on, and the next launch opens no onboarding while all three permissions are granted.
8. 🤫 › Permissions needed… or Settings › Permissions… Expected: the same window, at step 1.

### M-UPD-1: updating from an older build
Test feed: a pre-release whose assets hold `appcast.xml` and the DMG (pre-release assets are public; the Worker ignores pre-releases). Both builds must be release builds signed with the same Developer ID and carry the committed `SUPublicEDKey`.
1. Install build A (for example 0.2.0) from its DMG, grant the permissions, sign in, turn on Start at login.
2. `defaults write io.backant.shepetal ShepetalFeedURL https://github.com/backant-io/shepetal/releases/download/<pre-release tag>/appcast.xml` (https only; anything else is ignored), then quit and open Shepetal.
3. 🤫 › Check for Updates… Expected: Sparkle's window offers build B (0.2.1). Click Install and Relaunch. Expected: Shepetal restarts as B (Settings › Version), with the permissions, the login item and the sign-in kept (no permission prompt, fn dictates straight away).
4. Clean up: `defaults delete io.backant.shepetal ShepetalFeedURL`.
5. Downgrade: drag build A's DMG copy over B in /Applications, open it, and click Check for Updates…. Expected: B is offered again. Sparkle never offers A to B.
6. From v0.1.0 (Apple Development signed, no Sparkle): it never updates itself. Install the first Developer ID DMG by hand once; macOS asks for Microphone, Input Monitoring and Accessibility again, and once to read the sign-in token (Always Allow) or you sign in again.

### M-UPD-2: an update waits for idle
1. With the test feed from M-UPD-1 and Settings › Install updates automatically on, start a long dictation (double-tap fn) right before a background check finds B (or click Check for Updates…, then Install and Relaunch while dictating).
2. Expected: no restart during the dictation; after Install and Relaunch, "Shepetal restarts to update when the dictation ends" next to 🤫, and the restart comes right after it ends. The same during a meeting recording and its transcription ("…when the meeting ends").
3. A background-downloaded update installs only once fn has been left alone for 20 minutes (or when you quit).
4. Turn Install updates automatically off. Expected: a found update shows as "Update to <version>…" in the 🤫 menu instead of a window popping up.
5. Point `ShepetalFeedURL` at an appcast whose DMG does not match its signature (edit one byte of a copy of the DMG and upload it to a pre-release with that appcast). Expected: "Update failed: …" next to 🤫 for a few seconds, nothing installs, and the 🤫 menu shows no status line.

### M-UNINST-1: uninstall, recordings kept
1. Open shepetal › Settings and scroll to the bottom. Expected: a small grey "Uninstall Shepetal…" link is the last item; there is no uninstall in the 🤫 menu.
2. Start a dictation (double-tap fn), click the link. Expected: the sheet says "Finish the dictation first" and Uninstall is disabled. Stop the dictation: within a second Uninstall is enabled.
3. Press Return. Expected: the sheet closes (Cancel is the default), nothing changed. Open it again and press Esc: same.
4. Open it again and click Uninstall without ticking the box. Expected: Shepetal quits; Shepetal.app, `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`, the dictionary model next to it (if downloaded) and `~/Library/Application Support/Shepetal/models` (the cleanup model, if downloaded) are in the Trash; Login Items no longer lists Shepetal; "Press 🌐 key to" is back to the value Shepetal replaced; the sign-in token is gone from Keychain Access (`io.backant.shepetal.account`); `~/Library/Application Support/Shepetal` is still there.
5. Drag Shepetal.app back out of the Trash and open it. Expected: it works again after onboarding (permissions, sign-in).

### M-UNINST-2: uninstall with the data
1. Tick "Also delete my recordings". Expected: the line changes to "Your recordings, transcripts and history also go to the Trash."
2. Click Uninstall. Expected: as M-UNINST-1, and `~/Library/Application Support/Shepetal` is in the Trash too, and `defaults read io.backant.shepetal` finds no domain.

### M-UNINST-3: a waiting update does not bring the app back
1. With the test feed from M-UPD-1 and automatic install on, let Sparkle download B in the background (Console: `Shepetal` "will install on quit"), then uninstall right away (fn untouched for less than 20 minutes, so it waits).
2. Expected: after Shepetal quits, /Applications/Shepetal.app stays gone (the uninstall stops `io.backant.shepetal-sparkle-updater` and trashes `~/Library/Caches/io.backant.shepetal`). If it comes back, the waiting installer must be stopped some other way: report it.

### M-SETUP-4: the 🌐 key at launch, restore and uninstall
1. Quit Shepetal. Set "Press 🌐 key to" to Show Emoji & Symbols. Open Shepetal.
2. Expected: "🌐 key set to Do Nothing so fn can dictate" next to 🤫 for a few seconds, and the setting reads Do Nothing. Quit and open Shepetal again: no message this time.
3. In Open shepetal > Settings choose Restore 🌐 key setting (Change Input Source, the value it first replaced). Expected: the setting is back to that value, and the button goes away.
4. The fallback for an app that won't open: run `/Applications/Shepetal.app/Contents/Resources/uninstall.sh`. Expected: Shepetal quits, is gone from /Applications and from Login Items, the 🌐 key setting is what it was before Shepetal changed it, and `~/Library/Application Support/Shepetal` is still there.

### M-SETUP-5: no false "fn not received"
"fn not received" only shows when the 🌐 key's keycode 179 reaches Shepetal and fn's keycode 63 does not (another app took fn). Ordinary keys never show it. The positive case cannot be produced by hand; `FnHealthTests` and `FnTapTests` cover it.
1. With all three permissions granted, type a few sentences in TextEdit. Hold Down arrow for 2 s, then Left arrow for 2 s. Press ⌘C, ⌘V, ⇧ with letters, ⌥←, ⌘Space (then Esc), ⌃⌘V. Hold ⌃⌥ together for 2 s. Press fn+Delete and fn+↓. Hold ⌃, then hold fn for 2 s, release both. Tap fn, double-tap fn, and hold fn for 2 s (a dictation, fine).
2. Expected: no "fn not received" next to 🤫 at any point, no yellow ring, and Open shepetal > Home shows no fn problem.
3. In System Settings > Privacy & Security > Input Monitoring, turn Shepetal off. Hold fn for 2 s. Expected: "Input Monitoring access was turned off" with a yellow ring and the Permissions window, not "fn not received". Turn Shepetal back on: within 2 s fn dictates again.

### M-SETUP-2: permissions survive a rebuild
1. With all three permissions granted, quit Shepetal, run `scripts/make-app.sh --install` (it must print "Signed with: Apple Development…" or "Developer ID…"), and open the app again.
2. Expected: no Permissions window opens, nothing is asked again, and fn dictation works straight away.

### M-SETUP-3: stays running in the background
1. Open Shepetal and use other apps for an hour, including full-screen apps and Space switches.
2. Expected: 🤫 is still in the bottom-left corner and in the menu bar, there was never a Dock icon, and fn still dictates. Quit shepetal from the 🤫 menu (or press ⌘Q while the menu is open): both 🤫 disappear.

### M-CRASH-1: crash recovery (F99)
Setup: shepetal installed from the .pkg and running (🤫 in the menu bar), with a TextEdit window in front.
1. In Terminal, run `pkill -9 -f 'Shepetal.app/Contents/MacOS/Shepetal$'`. This ends only the app: `pkill -x Shepetal` would also end its watchdog. Click back into TextEdit. Expected: 🤫 comes back within about 5 s, TextEdit keeps focus, and fn dictates again. (This assumes a license that allows dictation. Otherwise Home opens at every launch, the reopen included, as it already does.)
2. A real crash: wait a minute, then run `pkill -ABRT -f 'Shepetal.app/Contents/MacOS/Shepetal$'`. Expected: macOS shows "Shepetal quit unexpectedly", and 🤫 comes back within about 5 s. Click Reopen in that dialog. Expected: `pgrep -fl Shepetal` still shows exactly two lines, the app and `... --watchdog <that app's pid>`.
3. Choose Quit shepetal in the 🤫 menu and wait 10 s. Expected: 🤫 stays gone, and `pgrep -fl Shepetal` prints nothing.
4. Open shepetal, then run `pkill -f 'Shepetal.app/Contents/MacOS/Shepetal$'` (SIGTERM, what the installer and the uninstaller send). Expected: it quits at once and stays quit, and `pgrep -fl Shepetal` prints nothing.
5. Open shepetal. Run the command from step 1 four times, each time once 🤫 is back, all within a minute. Expected: after the fourth, 🤫 stays gone. Open shepetal: "shepetal kept quitting unexpectedly, so it stopped reopening itself" shows next to 🤫. Quit and open it again: the hint does not show.
6. With shepetal running, install the .pkg again. Expected: after the installer finishes, `pgrep -fl Shepetal` shows exactly two lines: `/Applications/Shepetal.app/Contents/MacOS/Shepetal` and `/Applications/Shepetal.app/Contents/MacOS/Shepetal --watchdog <that app's pid>`.

### M-PERM-1: Microphone
1. Quit Shepetal. Run `tccutil reset Microphone io.backant.shepetal`.
2. Open Shepetal. The Permissions window lists Microphone with ⚠️.
3. Click Grant… next to Microphone. macOS asks for microphone access. Allow it.
4. Expected: the row turns ✅ within a second.

### M-PERM-2: Input Monitoring
1. Run `tccutil reset ListenEvent io.backant.shepetal` and open Shepetal.
2. Click Grant… next to Input Monitoring. System Settings opens at Privacy & Security > Input Monitoring. Turn on Shepetal.
3. Expected: the row turns ✅, and within 2 s Home's fn key line reads "Watched: hold fn to talk, double-tap for hands-free". You don't need to restart.

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

### M-CRT-1: creator mode label (F114)
1. Choose Open shepetal in the 🤫 menu, then Settings, and turn on "Creator mode: show “Dictating with shepetal” next to 🤫 while recording".
2. Start a QuickTime Player screen recording (File › New Screen Recording, record the entire screen).
3. Click into a TextEdit document, hold fn and talk for about 5 s, then release.
4. Expected: "Dictating with shepetal" shows to the right of 🤫 while you hold fn, 🤫 itself does not move, and the label goes away on release (the blue processing ring has no label). The text is inserted as usual.
5. Double-tap fn for hands-free, talk, then tap fn to stop. Expected: the label shows for the whole hands-free recording and goes away when it stops. Hold fn again and press Esc. Expected: the creator label is replaced at once by "Cancelled" in the same place, and after 3 s nothing shows next to 🤫.
6. Stop the QuickTime recording and play it back. Expected: the label is visible in the video while you dictated.
7. Click on the label while it shows. Expected: the click goes to the app under it, and shepetal does not take focus.
8. Turn the toggle off and hold fn again. Expected: no label, only the red ring.
(The label's lifecycle, the frame and click-through are covered by `IndicatorTests`. This step checks it in a real screen recording.)

### M-LIVE-1: words while you speak (F13)
1. Choose Open shepetal in the 🤫 menu, then Settings, and turn on "Show words while you speak".
2. Click into a TextEdit document, hold fn and talk for about 10 s.
3. Expected: within about 1.5 s of your first words, they show to the right of 🤫 and keep updating about once a second: only the last few words, after "…" once there are more. 🤫 itself does not move, and nothing is typed into TextEdit while you talk.
4. Release fn. Expected: the words next to 🤫 go away at once (the blue processing ring has no label), and only the final text is inserted: the whole dictation, about as fast as with the setting off.
5. Double-tap fn for hands-free and talk. Expected: the words show the same way. Tap fn to stop. Expected: the same as step 4.
6. Hold fn, talk for about 3 s, then press Esc. Expected: the words are replaced at once by "Cancelled", nothing is inserted, and after 3 s nothing shows next to 🤫.
7. Hold fn, talk, and click into another window before you release. Expected: nothing is pasted into the other window (the note next to 🤫 says the text is on the clipboard), and the words never took focus.
8. Turn on creator mode as well, hold fn and talk. Expected: "Dictating with shepetal" shows the whole time, with the words after it ("Dictating with shepetal · …"). Release fn and turn creator mode off again.
9. Turn "Show words while you speak" off and hold fn again. Expected: only the red ring, no words.
(The throttle, the 10 s window, the cancel at release, late partials, the creator label and the label's lifecycle are covered by `LiveTextTests`, `LiveCaptionTests` and `IndicatorTests`, and `scripts/e2e-mac.sh` checks partials, a partial running at release and the latency bars with live text on. This step checks real speech from a real mic.)

### M-FN-1: hold to talk
1. Click into a TextEdit document. Hold fn, say "Testing one two three, this is a hold to talk check.", then release.
2. Expected: a red ring while you hold, a pulsing blue ring after release, then the text appears at the cursor. Your earlier clipboard is back (Cmd+V elsewhere pastes what you had copied before).

### M-FN-2: double-tap for hands-free
1. In TextEdit, tap fn twice as fast as you can (the second press within half a second of releasing the first).
2. Expected: the ring turns orange on the second press and stays orange after you release.
3. Speak two sentences without holding anything. Tap fn once.
4. Expected: the ring turns blue on that tap and the text appears, with no further fn press. Recent in the 🤫 menu shows it.
5. Tap fn once, wait about 1 s, then tap again. Expected: not hands-free. Each tap shows the short-press hint (M-FN-3).

### M-FN-3: short press
1. Tap fn once, briefly (under half a second), and don't tap again.
2. Expected: nothing is inserted and the ring never turns orange (a short press is never hands-free). "Hold fn to talk · double-tap for hands-free" shows next to 🤫 about half a second after the release, for about 3 s, without another fn press.
3. Expected: Recent in the 🤫 menu has a "(too short)" entry, and a new WAV is in Settings > Open recordings folder.

### M-FN-4: fn as a modifier
1. In a long TextEdit document, hold fn and press Down arrow within the first second, keep both held for about 2 s, then release.
2. Expected: the view pages down. No ring stays red, nothing is transcribed or pasted, and no hint shows.
3. Type a word, then press fn+Delete quickly a few times.
4. Expected: characters after the cursor are deleted, nothing is inserted, and no hint shows. Recent in the 🤫 menu has a "(cancelled)" entry for each press, and each has a WAV in Settings > Open recordings folder.
5. Hold fn for about 2 s, then press Down arrow while still holding and speaking. Expected: the dictation goes on and is inserted on release.

### M-BLOCK-1: dictation off in one app (F102)
1. Click into a TextEdit document, then open the 🤫 menu. Expected: "Turn off dictation in TextEdit" right after Shortcuts…, Microphone and Languages. Click it.
2. In TextEdit, hold fn, say "This must not be typed.", and release. Expected: "Dictation is off in TextEdit" shows next to 🤫 for about 3 s. The ring never turns red, nothing is inserted, Recent in the 🤫 menu has no new entry, and Settings > Open recordings folder has no new WAV.
3. Tap fn twice quickly. Expected: the same hint, and the ring never turns orange. In a long document, hold fn and press Down arrow. Expected: the view pages down (fn still reaches TextEdit).
4. Switch to Notes, hold fn and dictate a sentence. Expected: it is inserted as usual (only TextEdit is off).
5. With Notes in front, open the 🤫 menu. Expected: "Turn off dictation in Notes", and below it "Dictation is off in (click to turn back on)" with TextEdit in it. Leave it.
6. Choose Quit shepetal in the 🤫 menu and open shepetal again. In TextEdit, hold fn. Expected: the hint again (the setting survives a restart).
7. Open the 🤫 menu in TextEdit. Expected: "Turn on dictation in TextEdit". Click it, then hold fn and dictate. Expected: the text is inserted, and the "Dictation is off in" submenu is gone from the menu.

### M-MEDIA-1: mute or pause media while dictating (F09)
1. Play a song in Music.app. Choose Open shepetal > Settings: both "Mute other audio while dictating" and "Pause media while dictating" are off. Hold fn, say a sentence, release. Expected: the music keeps playing at the same volume the whole time.
2. Turn on "Mute other audio while dictating" only. Hold fn and say a sentence. Expected: about half a second after the press, the music goes silent, and the menu bar's sound icon shows muted. On release the sound comes back, the text is inserted, and the song never stopped.
3. Same toggle. Double-tap fn for hands-free, say a sentence, tap fn. Expected: silent while recording, sound back after the tap. Then press fn+Delete in a text field, and tap fn once briefly. Expected: the music never drops out. Then hold fn for about 0.7 s and, still holding it, press the left arrow. Expected: the music may drop out for a moment and comes back at once, and the cursor moves.
4. Mute the Mac yourself (the mute key), then dictate. Expected: it stays muted afterwards. Unmute, start a dictation, press the mute key twice (muted, then unmuted) during it, and release. Expected: the sound is on at the end. Then set the volume to about half, start a dictation, and plug in headphones while recording. Expected: the speakers are unmuted at the end, and the headphones were never muted.
5. Turn mute off and turn on "Pause media while dictating" only. Hold fn for 3 s with Music playing. Expected: Music pauses about one second after the press and resumes on release. Hold fn for about 0.7 s and, still holding it, press the left arrow. Expected: Music never pauses. Hold fn for about 1.2 s and say one word. Note whether Music resumes. If it stays paused, that is known limit (b) in #218, not a crash. Pause Music yourself, play a YouTube video in a browser tab, and hold fn for 3 s. Expected: YouTube pauses and resumes. Note how long a dictation must be for the tab to resume. A tab that stays paused after a short dictation is known limit (a).
6. Pause everything and dictate with nothing playing. Expected: nothing starts playing, and Music.app does not open.
7. Pause a song in Music.app (it stays in Control Center's Now Playing). In Terminal, make a silent minute and play it: `python3 -c "import wave;w=wave.open('/tmp/silence.wav','wb');w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(bytes(16000*2*60))" && afplay /tmp/silence.wav`. While it plays, with pause on, hold fn for 4 s in a text field and say a sentence. Expected: Music may start for up to about a second, then pauses again. It is paused at the release and stays paused afterwards, and the text is inserted.
8. Play a YouTube video in a browser tab, pause it yourself, and within 2 s hold fn for 3 s and say a sentence. Note whether the video starts and keeps playing after the release. If it does, that is known limit (a) in #218. The text is inserted either way.
9. Quit Music.app and every other player, so Control Center shows nothing in Now Playing. Start the silent `afplay /tmp/silence.wav` from step 7, click into a TextEdit document, and with pause on hold fn for 3 s and say a sentence. Note whether Music.app opens. If it opens and takes focus, the paste is skipped with "The window changed while you spoke" and the text stays for Cmd+V: that is known limit (c) in #218. If Music starts playing, it pauses again within about a second.
10. Join a test call in FaceTime or Zoom with music playing in Music, both toggles on, and dictate. Expected: no mute and no pause, and the call audio is never cut.

### M-INS-1: TextEdit
1. Type "Please" in a TextEdit document, leave the cursor right after it, then hold fn and say "Send the report today."
2. Expected: "Please send the report today." The text starts with a space and a lowercase "send".
3. If it goes in as dictated instead ("Please" then "Send the report today." with its capital), Shepetal could not read the field. Run `log stream --predicate 'eventMessage CONTAINS "shepetal: context"'` in Terminal, dictate again, and write down the line it prints (`shepetal: context: <attribute> unreadable (AX <code>), text goes in as dictated`). It never shows your text.

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
3. Expected: Recent in the 🤫 menu has a "(no speech)" entry, and a new WAV is in Settings > Open recordings folder.
4. Hold fn, say only "um, uh", then release. Expected: the same as steps 2 and 3.
5. Hold fn and say a quiet "yes" from about an arm's length away. Expected: "yes" is inserted. If it shows "No speech heard" instead, or room noise in step 1 got transcribed, the -60 dBFS floor does not fit this mic: note the mic and the room in #15. You can try another floor with `defaults write io.backant.shepetal speechFloorDb -float -65` and relaunch.

### M-RET-1: delete after 24 hours
1. In Open shepetal > Settings set Recordings to Delete recordings after 24 hours.
2. Expected: recordings older than 24 h are gone from the recordings folder right away. Newer ones stay. (The timing itself is covered by `StorageTests.testRetention24hDeletesOnTime`.)
3. Meetings follow the same choice. Record a short meeting (M-MTG-1, or start and stop one by hand) and leave Shepetal running. Expected about 25 h later: its folder (Me.wav, Others.wav) is gone from `~/Library/Application Support/Shepetal/meetings/`, but the meeting is still in Meetings with its transcript and summary, and search still finds it. Only the audio is deleted, as with dictation. A meeting recorded in the last 24 h keeps its folder, and so does one that is still recording. (The timing is covered by `MeetingStoreTests.testRetentionDeletesOnlyTheAudioOfMeetingsEndedOver24hAgoButNeverOfTheOneRecording`.)

### M-RET-2: meeting transcripts deleted after N days (F81)
Setup: as in M-MTG-1, with at least one recorded meeting that has a summary and ended before today. Recordings is "Keep recordings".
1. In Open shepetal > Settings, under Recordings, set Meeting transcripts to "Delete transcripts after 1 day". Expected: the caption under it says only what was said goes, and the summary, your notes and folders stay, while the audio follows Recordings. There is no sound.
2. Open Meetings and open a meeting that ended more than a day ago, then click Transcript. Expected right away: "Transcript deleted after N days" and "Deleted on DD.MM.YY (today), as set in Settings under Meeting transcripts. The summary and your notes stay." Its Summary and Notes are unchanged, and Copy summary still pastes the summary. Its transcript window (🤫 > Past meetings) shows the summary, then the same line.
3. In the Meetings search, type a word that was only said in that meeting, and not in its summary or notes. Expected: the meeting is not found. A word from its summary still finds it. Its `Me.wav` and `Others.wav` are still in `~/Library/Application Support/Shepetal/meetings/`.
4. Record a short meeting (M-MTG-1 steps 1 to 6) and leave shepetal running. Expected while it records and right after: its transcript stays. About 25 h after it ended: the Transcript pane says "Transcript deleted after 1 day", the summary is still there, and its audio files are still in its folder.
5. Set Meeting transcripts back to Keep transcripts. Expected: new meetings keep their transcripts. Deleted ones stay deleted.
(The timing is covered by `MeetingStoreTests.testTranscriptRetentionDeletesOnlyTheTranscriptsOfMeetingsEndedBeforeTheCutoff`.)

### M-ESC-1: Esc cancels and keeps the audio
1. In TextEdit choose File > Open… so a dialog is open. Hold fn, say a sentence, and press Esc while still holding fn. Release fn.
2. Expected: nothing is inserted, the ring goes away, and "Cancelled" shows next to 🤫 for about 2 s. The Open dialog is still open, because Shepetal kept that Esc from the app (with Accessibility on).
3. Double-tap fn for hands-free, say a sentence, press Esc. Expected: the same.
4. With nothing recording, press Esc. Expected: the Open dialog closes, because an idle Esc reaches the app.
5. Expected: Recent in the 🤫 menu has a "(cancelled)" entry for steps 1 and 3, and each has a WAV in Settings > Open recordings folder.

### M-ESC-2: Esc while transcribing
1. Double-tap fn in TextEdit and talk for about a minute (a longer recording takes longer to transcribe). Tap fn and press Esc right after it, while the ring pulses blue.
2. Expected: nothing is inserted and "Cancelled" shows. Recent has the entry with its text, marked cancelled in `history.sqlite` (`sqlite3 ~/Library/Application\ Support/Shepetal/history.sqlite "select outcome, text from history order by created_at desc limit 1"`). If the text was already inserted, Esc came too late. Try again with a longer recording.

### M-SLOW-1: slow-processing notice (F18)
1. Run `defaults write io.backant.shepetal slowNoticeSeconds 0.1`, then quit and reopen shepetal.
2. In TextEdit, hold fn, say a sentence of about ten words and release. Expected: "Still transcribing · long recordings take a moment" shows next to 🤫 while it works, then goes away when the text is pasted. The text is pasted once, into TextEdit.
3. Start another dictation, release, and press Esc right away. Expected: nothing is pasted and no notice stays.
4. Run `defaults write io.backant.shepetal slowNoticeSeconds 0`, quit and reopen, and dictate again. Expected: no notice.
5. Reset: `defaults delete io.backant.shepetal slowNoticeSeconds`, quit and reopen. A normal short dictation shows no notice (default 3 s).

### M-KEY-1: fn+Space hands-free toggle
1. In TextEdit, with nothing recording, press fn+Space (fn first) and release both. Expected: the ring turns orange and stays. No space character is typed.
2. Speak a sentence, then press fn+Space again. Expected: the text is inserted, again without an extra space.
3. Press fn+Space, then press it again within half a second. Expected: the recording is thrown away. Nothing is inserted, and Recent has a "(cancelled)" entry.

### M-KEY-2: hold fn, then add Space
1. In TextEdit hold fn and start speaking. Still holding fn, press Space, then release both.
2. Expected: the ring turns from red to orange and recording goes on. No space is typed.
3. Tap fn once. Expected: the whole dictation is inserted.

### M-KEY-3: Shortcuts window
1. In the 🤫 menu choose Shortcuts…. Expected: hold to talk fn, hands-free fn Space, cancel Esc, paste last ⌃ ⌘ V, copy last ⌃ ⌘ C, open notes Not set.
2. Click Change… next to Paste last transcript and press ⌘Tab. Expected: "⌘ Tab: macOS or most apps already use these keys." and the chord stays ⌃ ⌘ V.
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
5. Open the 🤫 menu. Expected: "Paste last transcript" with ⌃⌘V right-aligned, the way macOS shows shortcuts, and no Copy last text item. Choose it: the sentence is inserted. ⌃⌘C still copies (step 3).
6. Rebind Paste last transcript to ⌃⌥P (M-KEY-3 step 4). Expected: the menu shows ⌃⌥P next to Paste last transcript. Rebind it to a mouse button: the shortcut moves into the title, "Paste last transcript (Mouse 4)". Reset to defaults.

### M-MIC-1: choosing the mic
1. Plug in a USB or Bluetooth mic you have never used with Shepetal. Expected: "New mic: <its name>" shows next to 🤫. Unplug and plug it in again: nothing shows.
2. Open 🤫 > Microphone. Expected: "Automatic (<mic in use>)" is checked, every input device is listed, and a "Prefer <name>" item is listed for each.
3. Choose the USB mic's name (this forces it). Dictate a sentence while tapping the USB mic, then play the newest WAV from Settings > Open recordings folder. Expected: the tap is loud, so the USB mic recorded.
4. Choose Automatic, then "Prefer <USB mic>". Dictate again. Expected: the USB mic records. Unplug it. Expected: "Using <next mic>" shows next to 🤫, and the next dictation works.

### M-MIC-2: closed lid
1. On a MacBook with an external display, keyboard and a USB mic, close the lid. Dictate. Expected: the USB mic records, even when MacBook Pro Microphone is forced or ranked first (the Microphone menu leaves it out while the lid is closed, and shows it again once the lid is open).
2. Unplug the USB mic and dictate. Expected: no recording starts, and a yellow ring with "The lid is closed and no other mic is connected. Open the lid or plug in a mic."

### M-MIC-3: mic disconnected mid-dictation
1. Force a USB or Bluetooth mic. Double-tap fn for hands-free, say a sentence, then unplug the mic (or switch off the headset) while still recording.
2. Expected: recording stops, "Mic disconnected" shows next to 🤫, what you said before the unplug is inserted, and its WAV is in Settings > Open recordings folder.

### M-MIC-4: dead mic
1. Force an input that sends only silence: a loopback driver with nothing playing (for example Microsoft Teams Audio when Teams is closed, or BlackHole). Double-tap fn for hands-free and wait.
2. Expected: after about 5 s "No sound from <name>. Is it muted?", and after about 15 s "Still no sound from <name>. Pick another mic in the 🤫 menu." Tap fn: the WAV is kept and holds silence.

### M-MIC-5: Bluetooth and quiet recordings
1. With AirPods connected and preferred, dictate once. Expected: "Tip: the built-in mic records clearer than Bluetooth" shows once. Dictate again: it does not show again, not even after a relaunch.
2. On the built-in mic, hold fn and say a sentence very quietly from about an arm's length away. Expected: after the text lands, "Speak closer or use a wired mic". A normal sentence at normal distance does not show it. If it shows too often or never, tune it with `defaults write io.backant.shepetal micQuietFloor -float 0.002` (RMS, default 0.003) and relaunch.

### M-MIC-6: Voice Isolation in a loud room (#75)
1. With music or a TV playing loudly near the Mac, or in a café, hold fn and dictate two sentences at a normal voice. Expected: the text has the sentences and none of the background speech or lyrics.
2. During any dictation, open Control Center > Mic Mode. Expected: Shepetal is not listed there, and Shepetal never opens that menu itself.
3. Open the dictation in the hub and play it. Expected: the recording plays back raw, with the background noise still in it. Only the text was made from the isolated voice.
4. If words go missing in a quiet room, lower the effect with `defaults write io.backant.shepetal voiceIsolationMix -float 50` (percent, default 100; 0 turns it off) and relaunch.

### M-MIC-7: every dictation records (21.10.26 retest: empty WAVs)
1. With the system input on MacBook Pro Microphone and Microsoft Teams (or Zoom, BlackHole) installed, hold fn, say a sentence, release. Expected: the text is inserted, no "No audio from the microphone", and the newest WAV in Open recordings folder is longer than 44 bytes.
2. Keep your iPhone nearby and unlocked (macOS lists its Continuity mic before the built-in one). Set System Settings > Sound > Input to Microsoft Teams Audio. Open 🤫 > Microphone. Expected: "Automatic (MacBook Pro Microphone)", not the iPhone, and a dictation records your voice. This dictation moves the engine off the system default, so in step 4 its "opened" line can have one "configuration change" line after it. Set the input back.
3. Choose the iPhone or a USB mic in 🤫 > Microphone (not the system input) and dictate. Expected: it records, and the menu lists no CADefaultDeviceAggregate device.
4. The mic's log, without any audio or text: `/usr/bin/log show --last 10m --predicate 'process == "Shepetal" AND eventMessage BEGINSWITH "shepetal: mic"'` (zsh's own `log` command shadows /usr/bin/log). Expected: one "opened <mic>" line per dictation, at most one "configuration change" line after it, and no "dictation ended" line (a mic that stops partway ends with "<mic> stopped sending audio").

### M-LANG-1: languages
Setup: for steps 4 and 5, the alternative engine's file from `docs/models.md` (Languages on the Mac), `ggml-large-v3-turbo-q5_0.bin`, is in `~/Library/Application Support/Shepetal/models/`.
1. Open 🤫 > Languages. Expected: Automatic is checked, and the list holds the languages by their names in the system language (on an English Mac: German, French, Japanese).
2. Check German and French. Expected: Home's speech recognition line stays "On-device speech recognition (standard engine)", with no reload. Say a German sentence in TextEdit. Expected: German text.
3. With German and French still checked, say a Spanish sentence of at least five words, for example "Por favor, envía el informe al equipo antes del viernes". Expected: the text is pasted as heard, and "This sounded like Spanish, which is not in your Languages" shows next to 🤫 for 4 s. Say "Sí, claro." Expected: no hint, because the text is too short to tell.
4. Uncheck German and French, and check English and Japanese. Expected: Home's line reads "On-device speech recognition (alternative engine)" within a few seconds. Without the prerequisite, Home's line says "On-device speech recognition for English, Japanese is not installed", and dictation shows "Speech model is not loaded" until you install it or choose Automatic.
5. Mixed language: with English and Japanese checked, say an English sentence, then in a second dictation a Japanese one (or play `say -v Kyoko "明日の会議の資料を、金曜日までに送ってください。"` into the mic). Expected: the English text in English and the Japanese text in Japanese script, each pasted into TextEdit, with no hint next to 🤫. The second dictation is not slower than the first: the engine is not reloaded.
6. Choose Automatic. Expected: the line goes back to the standard engine.

### M-TRN-1: translate while dictating (F41)
Setup: macOS 15 or later. German is not downloaded in System Settings > General > Language & Region > Translation Languages (remove it if it is).
1. Open 🤫 > Languages. Expected: the first item is "Translate to English", unchecked, above Automatic.
2. Check Translate to English. In TextEdit, dictate "Bitte schick mir den Bericht bis Freitag." Expected: the German is pasted, and "Not translated: download German for translation in 🤫 > Languages" shows next to 🤫 for 4 s. No download prompt opens during the dictation.
3. Open 🤫 > Languages. Expected: "Download German for translation…" right under Translate to English. Choose it. Expected: a small "shepetal" window that says "Getting German ready for on-device translation…" and the system's download prompt. Approve the download. Expected: "German is ready for translation" shows next to 🤫, the window closes, and the Download item is gone.
4. Turn Wi-Fi off. Dictate the same German sentence into TextEdit, and time it with a stopwatch from releasing the key to the English landing. Expected: English lands in TextEdit ("Please send me the report by Friday." or close), and TextEdit stays the active app the whole time, with no window showing. Write the time into docs/models.md, Translation (F41) > Latency. In Open shepetal > History, the row's text is the English and its raw text (Show raw) is the German. Turn Wi-Fi back on.
5. Dictate "Send the report to Anna by Friday." Expected: it lands as said, with no hint.
6. In History, re-transcribe the row from step 4. Expected: its text is English again.
7. Uncheck Translate to English, and dictate the German sentence. Expected: the German lands, with no hint.

### M-DICT-1: personal dictionary
1. Choose Open shepetal > Settings > Dictionary…. Expected: `dictionary.txt` opens in your default text editor, holding only comment lines that explain the format. `ls -l ~/Library/Application\ Support/Shepetal/dictionary.txt` shows `-rw-------`.
2. Add the lines `GitHub` and `asap => as soon as possible`, save, and without restarting Shepetal dictate "push it to github asap".
3. Expected: "Push it to GitHub as soon as possible." A word that only contains "asap" (for example "asaps") is left alone.

### M-DICT-2: dictionary words with the default model (F39, #30)
1. Keep 🤫 > Languages on Automatic. If `~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml` exists, move it out of that folder. Choose Open shepetal > Settings > Dictionary… and leave only the comment lines. Open the 🤫 menu. Expected: it has no dictionary support line, and the folder is still missing (nothing downloaded on its own).
2. In the same `dictionary.txt`, add the lines `Postgres`, `Redis` and `useEffect`, and save. Open the 🤫 menu. Expected: "Download dictionary support (about 100 MB)" is in the first group at the top, above Record meeting, with no yellow mark. In TextEdit, dictate "we moved the cache from redis to postgres". Expected without the download: "Redis" is cased right, "Postgres" can come out misspelled (this Mac wrote "postgars").
3. Choose "Download dictionary support (about 100 MB)" and open the 🤫 menu again while it runs. Expected: "Downloading dictionary support…" next to 🤫, and the menu has no dictionary support line while it runs. Then "Dictionary support is ready" next to 🤫. The menu no longer has the line, and the folder from step 1 now holds `vocab.json`.
4. Right after "Dictionary support is ready", dictate the sentence from step 2 again in TextEdit. Expected: exactly "We moved the cache from Redis to Postgres.", inserted as fast as before the download. Then dictate "then call the use effect hook inside the component". Expected: "Then call the useEffect hook inside the component."
5. Dictate "I made a few edits and the build is ready for review". Expected: unchanged. No dictionary word takes the place of "edits" or "ready".
6. If you speak Spanish, dictate "las redes sociales están llenas de ruido hoy" (or a sentence in another language you speak that has a word close to Redis or Postgres). Expected: the sentence as spoken, with "redes" kept. The dictionary does not change a dictation in another language.
7. Turn Wi-Fi off, quit and relaunch shepetal, and dictate the sentence from step 2. Expected: the same text as in step 4.

### M-SNIP-1: snippets (F40)
1. Choose Open shepetal > Settings > Snippets…. Expected: `snippets.toml` opens in your text editor (TextEdit when no app opens .toml files), holding only comment lines that explain the format. `ls -l ~/Library/Application\ Support/Shepetal/snippets.toml` shows `-rw-------`.
2. Add these two lines and save:
   `"my address" = "221B Baker Street\nLondon"`
   `"my signature" = "**Ada Lovelace**\n[backant.io](https://backant.io)"`
3. Without restarting shepetal, click into the middle of a sentence in a TextEdit rich-text document and dictate "My address." Expected: two lines, "221B Baker Street" and "London", exactly as written: no added space, no lowercase, no period.
4. Dictate "Send it to my address please". Expected: the sentence with the address in place of "my address".
5. In a new Mail message, dictate "my signature". Expected: "Ada Lovelace" in bold, a new line, then "backant.io" as a link to https://backant.io, in the message's own font. Do the same in the TextEdit rich-text document: bold and a link.
6. In TextEdit, choose Format > Make Plain Text and dictate "my signature". Expected: "Ada Lovelace" and "backant.io" on two lines, with no `**`, brackets or tags.
7. In Terminal, run `cat`, dictate "my signature", then press Ctrl+C. Expected: the same two plain lines, with no markup.
8. Edit "my address" in the file, save, and dictate it again. Expected: the new text, without restarting.

### M-STYLE-1: styles per app category (F37)
1. Open shepetal > Settings > Dictionary… and add the line `GitHub` if it is not there yet. Save.
2. Open shepetal > Settings. Expected: a Styles group with four pickers: Work messages, Personal messages, Email and Other apps. Each one is on Formal and has an example sentence under it. Switch Work messages through Casual, Very casual and Excited. Expected: the example under it changes each time: no comma after the greeting and no final period, then all lowercase, then a "!" at the end. Set Work messages to Casual and Personal messages to Very casual. Leave Email and Other apps on Formal.
3. In TextEdit, dictate "Hey Anna, I pushed the fix to GitHub." Expected: the same text as before styles, with the comma and the final period (TextEdit is Other, which is on Formal).
4. In the Slack app, click into a message box and dictate the same sentence. Expected: "Hey Anna I pushed the fix to GitHub": capitals kept, no comma after "Anna" (when the speech engine wrote one), no final period. If the speech engine wrote "Hey, Anna, …", the comma after "Hey" goes and the one after "Anna" may stay; note what you got. Then dictate "Can you review it today?". Expected: it ends in "?".
5. In Messages, dictate the same sentence. Expected: "hey anna i pushed the fix to GitHub": all lowercase, "i" too, no final period, and "GitHub" as in the dictionary.
6. In Mail, in a new message's body, dictate the same sentence. Expected: the words as in TextEdit (Email is on Formal), laid out as an email (F36): "Hey Anna,", a blank line, then "I pushed the fix to GitHub." Set Email to Excited and dictate "The contract is signed." Expected: "The contract is signed!"
7. In Safari or Chrome, open Slack at app.slack.com, click into a message box, and dictate the sentence from step 3. Expected: Casual, as in step 4.
8. In Open shepetal > History, choose Re-transcribe on the Messages row from step 5. Expected: the row's text is very casual again, even though the shepetal window is the app in front.
9. Quit shepetal from the 🤫 menu and open it again. Expected: Settings still shows the picks from steps 2 and 6. Set all four back to Formal and dictate in Slack. Expected: the text has the comma and the final period again.

### M-EMAIL-1: email layout and signature (F36)
1. Open shepetal > Settings. Expected: an Email section with an empty Signature field and a note that lists the email apps. Leave the field empty.
2. In Mail, open a new message and click into the body. Hold fn and say "Hi Anna, thanks for the update. Best regards." Expected: "Hi Anna,", a blank line, "Thanks for the update.", a blank line, then "Best regards," with nothing under it.
3. Type "Pavel" into Settings > Email > Signature. Dictate the same sentence into Mail again. Expected: the same layout, with "Pavel" on the line under "Best regards,". Then say "Thanks for the call. Cheers, Anna". Expected: "Thanks for the call.", a blank line, "Cheers,", then "Anna" below it, not Pavel.
4. In Safari, open Gmail (mail.google.com), start a new message, click into the body and dictate the sentence from step 2. Expected: the same layout as in step 3.
5. In Notes, dictate the sentence from step 2. Expected: one line, as dictated, with no line breaks and no signature.
6. In Mail, say "Hallo Anna, wie geht es dir? Viele Grüße". Expected: "Hallo Anna,", a blank line, "wie geht es dir?", a blank line, "Viele Grüße" (no comma), then "Pavel".
7. In Settings > Formatting per app, set Mail to Raw and dictate the sentence from step 2 into Mail. Expected: one line, as heard. Set Mail back to Default, then clear the signature.

### M-VOICE-1: My voice (F38)
Needs the cleanup model ("Cleanup: On" on Home).
1. Open shepetal > Settings. Expected: a My voice group with one field for how your text should read and three Writing sample fields, a Save button (it can be clicked only after a change), and a note under them.
2. Type `Never use exclamation marks. Always use contractions.` in the first field, and `Can't make it today, I'll send the notes tonight.` and `I don't think it's ready yet, let's wait for the review.` as samples 1 and 2. Click Save. Expected: Save can no longer be clicked. In Finder, `~/Library/Application Support/Shepetal/voice.json` exists, and `ls -l` on it shows `-rw-------`.
3. In TextEdit, hold fn and say "I do not think we can make the demo on Friday!" Release. Expected: "I don't think we can make the demo on Friday." without "!", within about a second of release. On a Mac with less than 16 GB, which uses the smaller model, the "!" may stay.
4. Hold fn and say "Send it to John, I mean Jane, it is urgent." Release. Expected: the correction is made ("Send it to Jane, ..."); "it is" may become "it's".
5. Hold fn and say "What is the capital of Australia?" Release. Expected: the question as you said it, never an answer. Say "Can you translate this into German?". Expected: that sentence in English, never a German one.
6. Set Settings > Styles > Other apps to Excited. Dictate "We are done." in TextEdit. Expected: it ends with "!" (the style runs after My voice). Set Other apps back to Formal.
7. Clear the field and every sample, then click Save. Expected: voice.json is gone. Dictate "I do not think so." Expected: "I do not think so." as before F38.

### M-FMT-1: formatting per app (F33)
1. Hold fn and say "um, on the fifth of march" into a TextEdit document, then do the same at a Terminal prompt. Do not press Return in Terminal. Expected: both get "On 05.03.". In Terminal the first letter may be lowercase ("on 05.03."): the cursor fit lowercases the first word after a shell prompt when shepetal can read the line. Both are a pass.
2. Choose Open shepetal > Settings. Expected: a "Formatting per app" section with All apps set to Formatted, and rows for Terminal and TextEdit, each set to "Default (Formatted)".
3. Set Terminal to Raw and TextEdit to Formatted. Dictate the same sentence into each again. Expected: Terminal gets the words as heard, "Um, on the fifth of March." with the "um" and the spoken date (or "um, on the fifth of March." after the prompt, as in step 1), and TextEdit gets "On 05.03.".
4. In History, choose Re-transcribe > the entry marked "(current)" on the newest Terminal row. Expected: its text is still the raw words.
5. Set All apps to Raw. Expected: Terminal and TextEdit keep their own choices, and the Default rows now read "Default (Raw)". Dictate the sentence into Notes. Expected: Notes gets the raw words, and TextEdit still gets "On 05.03.".
6. Choose Quit shepetal and open it again. Expected: Settings shows the same choices. Set All apps back to Formatted and Terminal back to Default.

### M-INS-5: space before the following word (F109)
1. In TextEdit type "Hello world", then put the cursor right before "world". Hold fn, say "big", then release.
2. Expected: "Hello big world", with one space on each side of "big".
3. Select "big world" and press Cmd+C. In Terminal run `pbpaste | xxd | head -2`. Expected: `c2 a0` (a non-breaking space) right after "big", not `20`.

### M-INS-6: replace a selection (F109)
1. In TextEdit type "Send the draft today." Double-click "draft". Hold fn, say "Final version.", then release.
2. Expected: "Send the final version today." The new words are lowercase like "draft", and there is no period after them.
3. Select "today." including its period. Hold fn and say "Tomorrow". Expected: "Send the final version tomorrow." with the period kept.
4. Select " version " with the spaces on both sides. Say "copy". Expected: "Send the final copy tomorrow." with no double or missing spaces.

### M-INS-7: a dictation in the middle of a sentence (F109)
1. In TextEdit type "I met John today." and put the cursor right before "John". Hold fn, say "Yesterday.", then release.
2. Expected: "I met yesterday John today." The dictation is lowercase, has no period, and has one space on each side.
3. On a new line type "I went home." and put the cursor right before its period. Hold fn and say "Today." Expected: "I went home today." with one period.
4. On a new line type "Hello. World." and put the cursor right before "World". Hold fn and say "Big news." Expected: "Hello. Big news. World." Between two sentences the dictation keeps its capital and its period.
5. On a new line type "Please" and leave the cursor after it. Hold fn and say "Send it to John at NASA." Expected: "Please send it to John at NASA." Only the first letter is lowercased.

### M-INS-8: mid-sentence in an Electron app (F109)
1. In VS Code (or Slack, or Obsidian) type "leave the cursor right after it", then click right before "the cursor". Hold fn, say "The cursor.", then release.
2. Expected: "leave the cursor the cursor right after it", with a lowercase "the cursor" and no period. Shepetal asks the app for its accessibility tree when the dictation starts. Note if VS Code then asks whether you use a screen reader, or turns on screen reader mode.
3. If any dictation in M-INS-1 to M-INS-8 went in as dictated (capital and period), run `log show --last 10m --predicate 'eventMessage CONTAINS "shepetal: context"'` in Terminal and add the lines to the report. Each dictation logs one line: the field's role, its length and the selection, or which attribute could not be read and the AX error code. The text itself is never logged.

### M-INS-9: remote desktop and VM viewers (F22)
1. Copy a word in TextEdit (your clipboard before the test).
2. Windows App: connect to a Windows PC or Cloud PC, open Notepad, click into it. Hold fn, say "hello from the mac", release. Expected: the text appears in Notepad once, no note next to 🤫, and History shows the row as inserted, not paste failed. Then ⌘V in TextEdit on the Mac pastes the word from step 1 (the clipboard came back).
3. Screen Sharing: connect to another Mac, click into a text field there, and dictate a sentence. Expected: as in step 2.
4. Shift+Insert: run `defaults write io.backant.shepetal pasteModes -dict-add com.microsoft.rdc.macos shift-insert`, quit and reopen shepetal. In Windows App, open a Linux terminal (a remote Linux desktop, or WSL in Windows Terminal) and dictate "list files". Expected: the text appears at the prompt. Then run `defaults delete io.backant.shepetal pasteModes`.
5. Typed: run `defaults write io.backant.shepetal pasteModes -dict-add com.apple.TextEdit typed`, quit and reopen shepetal. Dictate "Hello, world!" into TextEdit. Expected: it is typed, and ⌘V still pastes your word from step 1 (the clipboard was not touched). Dictate a word your layout cannot type (on a US layout, "café"). Expected: nothing is typed; the note says "Paste did not land. The text is on the clipboard: press ⌘V to paste it." Then run `defaults delete io.backant.shepetal pasteModes`.
6. Typed, dead keys (ABC-QWERTZ or German layout): run the `defaults write` command from step 5 again, then quit and reopen shepetal. Open shepetal › Settings › Dictionary… and add two lines: `caret test => ^abc` and ``backtick test => `echo` ``. In TextEdit, dictate "caret test". Expected: nothing is typed (not "âbc"). The note says "Paste did not land. The text is on the clipboard: press ⌘V to paste it.", and ⌘V pastes the text with "^abc". Then press A on the keyboard. Expected: "a", not "â" (no dead key was left waiting). Dictate "backtick test". Expected: the same, with "`echo`", and never "ècho". Remove both lines, then run `defaults delete io.backant.shepetal pasteModes`.
7. Local terminals: in Terminal, iTerm2 and WezTerm, dictate at a prompt. Expected: plain text, as before (no mode needed).
8. VNC viewer (RealVNC Viewer or TigerVNC), if you have one: on the far side, copy a word there, then click into a text field. On the Mac, dictate "hello from the mac". Expected: the sentence appears once, not the far side's word. If the far side's word or nothing is pasted, report it with the viewer's name. Wispr reactivates these viewers before it pastes, and shepetal never moves focus, so the VNC ids would then come out of the remote table.
9. For each other viewer you have (Jump Desktop, Screens, Parsec, TeamViewer, AnyDesk, Citrix Viewer, Parallels, VMware Fusion, UTM), run `osascript -e 'id of app "<name>"'` and add the id to the report, so the table in `Sources/ShepetalCore/PasteMode.swift` can be corrected.

### M-ENTER-1: "press enter" sends the message (F42)
1. Open shepetal › Settings and turn on "End a dictation with “press enter” to press Return".
2. In Messages or a Slack DM, click the message field. Hold fn, say "see you soon press enter", release. Expected: "See you soon." appears without "press enter" and is sent once.
3. Hold fn, say "see you soon press enter", click into another app's window (TextEdit) while still holding, then release. Expected: nothing is pasted or sent in either window; the note next to 🤫 says "The window changed while you spoke. The text is on the clipboard: press ⌘V to paste it."; ⌘V in the chat field pastes "See you soon." without the phrase.
4. Say only "press enter". Expected: nothing is pasted or sent; the note says "Say the text first, then “press enter”."
5. Say "press enter to continue" (mid-sentence): it is pasted as text and nothing is sent.
6. Turn the setting off and say "see you soon press enter": the phrase is pasted as text and nothing is sent.

### M-LINK-1: insert a copied link by voice (F28)
1. Quit shepetal from the 🤫 menu and open it again. Only links copied after launch are kept.
2. In Safari, open https://example.com. Click the address bar and press ⌘C. If macOS asks whether shepetal may paste, that is the pasteboard-privacy limit (#259): note the macOS version and what you chose. After that alert, F28 works only once shepetal is set to Always Allow in System Settings.
3. In an empty TextEdit document, hold fn, say "here it is insert link" and release. Expected: "Here it is https://example.com/", with the link where the command was and no "insert link". A comma after "is" is fine if the engine wrote one.
4. In Safari, open https://www.apple.com and copy the address the same way. Say "the first one was insert link two". Expected: the example.com link. Then say "insert the last link". Expected: the apple.com link.
5. Say "send me that link". Expected: pasted as text, with no link. Say "insert link five". Expected: the words stay as text, since only two links are kept.
6. In a password manager (Passwords, 1Password or Bitwarden), copy a password. Then say "insert link" in TextEdit. Expected: the apple.com link, never the password.
7. In TextEdit, type `https://us02web.zoom.us/j/123?pwd=abc123`, select it and press ⌘C. Say "insert link". Expected: the words "insert link" stay as text. Neither the Zoom link nor the apple.com link is pasted. A link with a password, code or token in it is never kept, but it still counts as the last link copied. Then say "insert link two". Expected: the apple.com link.
8. Open shepetal > History. Expected: the row from step 3 reads "Here it is, insert link." (or as heard). The link never goes into the history. Choose Re-transcribe on that row. Expected: "insert link" stays as words.
9. Quit shepetal and open it again. Say "insert link". Expected: the words stay as text, because links are kept in memory only.

### M-DATE-1: spoken dates become numbers (F32, docs/text-rules.md)
1. In an empty TextEdit document, hold fn and say "Twenty sixth of July twenty twenty-six." Expected: "26.07.26."
2. On a new line, say "Sechsundzwanzigster Juni sechsundzwanzig." Expected: "26.06.26."
3. On a new line type "and then we rest", put the cursor at the start of the line, and say "We leave on the first of March." Expected: "We leave on 01.03. and then we rest". The date keeps its last dot.
4. Say "May I ask a question?" Expected: it stays in words.

### M-CLEAN-1: download the cleanup model (F32)
1. On an Apple Silicon Mac without the model, open the 🤫 menu. Expected: at the top, the item "Download cleanup model (about 1.3 GB)" (about 0.5 GB on an 8 GB Mac), with no yellow mark and no grey Cleanup line. Open shepetal. Expected: Home's Cleanup line reads "Rules only (download the cleanup model from the 🤫 menu)". Neither shows a model or file name.
2. Before downloading, in TextEdit, hold fn and say "Let's meet on Tuesday, actually Wednesday, at three." Release. Expected: the sentence as you said it, "actually" included. Without the model, the rules never guess which half you meant.
3. Turn Wi-Fi off and click the download item. Expected: within a few seconds "Cleanup model download failed: check the internet connection and try again" shows next to 🤫 (#239), the download item is back in the 🤫 menu, with no grey line, and Home's Cleanup line reads "Rules only (the download failed; try again from the 🤫 menu)". Turn Wi-Fi back on.
4. Click the download item, then open the 🤫 menu again while it downloads. Expected: no download item and no grey line, so the download cannot start twice. Home's Cleanup line reads "Downloading the cleanup model…". While the file is checked, fn still works.
5. Once the file is in `~/Library/Application Support/Shepetal/models`, open the 🤫 menu again. Expected: no cleanup line or item, and the menu starts with "Record meeting". Home's Cleanup line reads "On".

### M-CLEAN-2: self-corrections and lists (F34, F35)
1. In TextEdit, hold fn and say "Let's meet on Tuesday, actually Wednesday, at three." Release.
2. Expected: "Let's meet on Wednesday at three." within a second of release.
3. Hold fn and say "Book a table for four. Scratch that. Book a table for six." Release. Expected: "Book a table for six."
4. Hold fn and say "Things to buy. First, milk. Second, eggs. Third, bread." Release.
5. Expected: "Things to buy:" and then three numbered lines, "1. Milk", "2. Eggs" and "3. Bread", each on its own line.
6. Hold fn and say "What is the capital of Australia?" Release. Expected: the question as you said it, not an answer.
7. Hold fn and say "We ship on Friday, I mean it." Release. Expected: the sentence as you said it, "Friday" included.
8. Recent in the 🤫 menu shows the cleaned text for each of these.

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
1. In Open shepetal > Settings, turn on Start at login.
2. Expected: the toggle stays on. If macOS wants approval instead, "Allow Shepetal in System Settings > General > Login Items" shows next to 🤫, System Settings opens at Login Items and the toggle stays off. Allow Shepetal there. The toggle is then on the next time you open Settings.
3. Log out and log back in. Expected: 🤫 is in the bottom-left corner and in the menu bar without you opening Shepetal, and there is no Dock icon.
4. Turn Start at login off. Expected: the toggle is off, and Shepetal is gone from Login Items. Onboarding turns it on (ticked by default, applied on Done); builds signed with the same certificate keep it.

### M-MENU-1: the 🤫 menu
Setup: all three permissions granted, speech recognition loaded, the cleanup model downloaded on an Apple Silicon Mac (M-CLEAN-1), no words in `dictionary.txt` or dictionary support downloaded (M-DICT-2), signed in with a trial of more than 7 days (or a build from source that does not require sign-in, signed in), at least one meeting recorded and at least one dictation.
1. Click 🤫 in the menu bar. Expected, top to bottom with a separator between each group: Record meeting, Past meetings › | Open shepetal, Notes… | Paste last transcript with ⌃⌘V right-aligned, Recent › | Shortcuts…, Microphone ›, Languages ›, Turn off dictation in <the app you were in> (M-BLOCK-1) | Help center, Send feedback… | Quit shepetal with ⌘Q right-aligned. Check for Updates… is there, enabled, only in a release build (Sparkle), in its own group after Open shepetal and Notes…; a build from source has none. Nothing above Record meeting, no emoji besides 🤫 in the menu bar, and "shepetal" in lowercase. No item is greyed out anywhere, in the submenus too: every line can be clicked and does something.
2. Hover Recent. Expected: the last dictations that have text, with no heading and no "(too short)" lines. Click one, then ⌘V in TextEdit: its text. With nothing dictated yet, the menu has no Recent.
3. Choose Help center. Expected: https://shepetal.backant.io/help opens in the browser. Until the help pages from #84 are merged and deployed, that URL is a 404 page: the item works, the page does not exist yet. Choose Send feedback…. Expected: a new mail to founder@backant.io with the subject "shepetal feedback".
4. In System Settings > Privacy & Security > Accessibility, turn Shepetal off. Open the menu. Expected: "Permissions needed…" at the very top with a yellow mark; choosing it opens the Permissions window. Turn Shepetal back on: the line is gone the next time the menu opens.
5. Signed out (Home > Sign out): the top of the menu has "Sign in to start your free trial…". With a test account 7 days or less from the end of its trial, or after it: "Get shepetal for $4.99…" instead. With more than 7 days left, or Yours forever, neither.
6. Open shepetal and check that nothing left the app: Home has the account line with Sign out, the speech recognition line and the Donate links (each opens its page); Settings has Recordings, Open recordings folder, Start at login, Dictionary… and Permissions….
7. Without the speech model (move `~/Library/Application Support/FluidAudio/Models` aside and restart): the top of the menu has "Download on-device speech recognition (about 470 MB)" with a yellow mark. Choose it, then open the menu again while it downloads. Expected: no download item and no grey line, so a second download cannot start; Home's Speech recognition line reads "Downloading on-device speech recognition…". Turn Wi-Fi off during a download: "Speech recognition download failed: …" shows next to 🤫 (#239), Home reads "Download failed: …" and the download item is back in the menu. Move the folder back.

### M-NEW-1: what's new after an update (F111)
1. Install **Shepetal-0.1.0.pkg** from the v0.1.0-mac release, or keep the 0.1.0 that is already installed. Open it and dictate once. Stay signed in, in the trial or with a license: a sign-in or trial-ended hint would replace the update hint, on purpose.
2. From main, build a newer DMG with `VERSION=0.1.1 scripts/make-dmg.sh`, quit shepetal, drag Shepetal from `dist/Shepetal-0.1.1.dmg` into Applications (replace), and open it. (After a Sparkle update, M-UPD-1, the same hint shows.)
3. Expected: next to the corner 🤫, **Updated to 0.1.1 · What's new… is on Home in the shepetal window** shows for about 6 s. No shepetal window opens.
4. Choose Open shepetal in the 🤫 menu, and on Home click **What's new…**. Expected: the window **What's new in shepetal** lists the release notes newest first, each under its version and a DD.MM.YY date. A 0.1.1 test build has no notes of its own, so 0.1.0 is at the top. The 🤫 menu has no What's new item.
5. Choose Quit shepetal in the 🤫 menu and open it again. Expected: no hint.

### M-HUB-1: open the shepetal window
1. Before you install this build, run `sqlite3 ~/Library/Application\ Support/Shepetal/history.sqlite 'select count(*) from history'` and note the number. Install and open the new build. Run the command again. Expected: the same number. (`HistoryTests.testOldDatabaseUpgradesWithoutLosingRows` checks this on a copy of the old schema.)
2. With all three permissions granted, quit Shepetal and open it again from Finder or Spotlight. Expected: only 🤫 appears. No Shepetal window opens.
3. Open the 🤫 menu and choose Open shepetal. Expected: a window titled "shepetal", in lowercase, with Home, History, Dictionary, Meetings and Settings tabs comes to the front.
4. Close it. Open `dist/Shepetal.app` again (Finder, Spotlight or `open dist/Shepetal.app`). Expected: the same window opens. No second 🤫 appears.
5. Home: expected rows for speech recognition ("On-device speech recognition (standard engine)", no model name), the fn key ("Watched…" once Input Monitoring is on), and the missing permissions with Open Permissions…. Each Donate link opens its page in the browser.

### M-HUB-2: search and copy
1. Dictate "Send the quarterly report today" and then "Call the dentist at 100% volume" into TextEdit (M-FN-1). Open History.
2. Type `QUARTERLY` in Search. Expected: only the first dictation is listed. Type `100%`. Expected: only the second. Clear the field. Expected: both, newest first.
3. Click Copy on the first, then Cmd+V in TextEdit. Expected: its text.
4. In TextEdit, hold fn, say "um, on the fifth of march" and release. Expected: TextEdit gets "On 05.03." (the filler is gone, the date is in numbers).
5. In History, click Show raw on that row. Expected: the row shows the words as heard ("Um, on the fifth of March." or close to it), its header line ends in "raw", and the button now reads Show cleaned. The "On 05.03." already in TextEdit does not change.
6. Click Copy on that row, then press Cmd+V in TextEdit. Expected: the raw words. Press ⌃⌘V (paste last). Expected: the raw words again. Open Recent in the 🤫 menu. Expected: its newest entry reads the raw words.
7. Choose Quit shepetal in the 🤫 menu, then open shepetal again. Expected: the row still shows the raw words with Show cleaned.
8. Click Show cleaned. Expected: the row shows "On 05.03." again, and Copy, ⌃⌘V and Recent give "On 05.03.".

### M-HUB-3: play, and recordings that are gone
1. Click Play on a dictation. Expected: you hear that recording.
2. In the recordings folder (Settings > Open recordings folder), run `touch -t 202001010000 <file>.wav` on one recording, then choose Settings > Recordings > Delete recordings after 24 hours.
3. Expected: that row now says "recording deleted", its Play and Re-transcribe are greyed out, and its text and Copy still work. Set Recordings back to Keep recordings if you want.

### M-HUB-4: re-transcribe
1. Click Re-transcribe on a dictation and choose the entry marked "(current)". Expected: "Re-transcribed with the standard engine" under the list. The row keeps its time, outcome and app.
2. Install the whisper.cpp fallback (README, Mac). Choose the other model in the same menu. It is listed as "With the alternative engine". Expected: after a few seconds, "Re-transcribed with the alternative engine", and the row's text is the whisper result. Without the fallback installed, expected: "Re-transcribe failed: The alternative engine is not installed", and the row is unchanged.

### M-HUB-5: archive
1. Click Archive on a dictation. Expected: it leaves the list.
2. Tick Show archived. Expected: it is back, marked "archived", with Unarchive. Click Unarchive and untick Show archived. Expected: it stays in the list.

### M-HUB-6: settings
1. In Settings, set Recordings to Delete recordings after 24 hours. Close and reopen the window. Expected: the same choice.
2. Open recordings folder opens Finder at the audio folder. Dictionary… opens `dictionary.txt` (M-DICT-1). Permissions… opens the Permissions window. Start at login is M-LOGIN-1, and Restore 🌐 key setting (shown only after Shepetal changed the setting) is M-SETUP-4.
3. Click Choose… next to Microphone. Expected: the same choices as 🤫 > Microphone (Automatic with the mic in use, each mic, Prefer …). Choose a mic, then open 🤫 > Microphone. Expected: the same mic is ticked there. Choose Automatic again.
4. Click Choose… next to Languages and tick one language. Expected: 🤫 > Languages ticks the same one. Choose Automatic again.
5. Click Shortcuts…. Expected: the same Shortcuts window as 🤫 > Shortcuts… opens.

### M-HUB-7: the Dictionary tab
1. Choose Open shepetal in the 🤫 menu and open the Dictionary tab. Expected: one row per entry in `~/Library/Application Support/Shepetal/dictionary.txt`, with a replacement shown as `btw → by the way`. With no file, or only comments in it, the tab says "No words yet".
2. Type `Kubernetes` in Word or phrase and click Add. Type `omw` in Word or phrase and `on my way` in Replace with, then press Return. Expected: both rows appear. Run `ls -l ~/Library/Application\ Support/Shepetal/dictionary.txt`. Expected: `-rw-------`. Open the file in a text editor. Expected: the header comments are still at the top, and the last two lines are `Kubernetes` and `omw => on my way`.
3. In TextEdit, hold fn and say "deploying to kubernetes, omw". Expected: the text has "Kubernetes" with a capital K, and "on my way" in place of "omw".
4. Click the star next to Kubernetes. Expected: the star fills, and the line in the file now reads `*Kubernetes`. Click the star again. Expected: it empties, and the line is `Kubernetes` again.
5. Type `OMW` in Word or phrase and `on my way now` in Replace with, and click Add. Expected: there is still only one omw row, now `OMW → on my way now`.
6. Click Edit as text…. Expected: dictionary.txt opens in the default text editor. In the editor, delete the Kubernetes line, add a line `Postgres` and save. Do not close the shepetal window. Click the star next to Kubernetes. Expected: the file is not changed. The note under the list says "dictionary.txt was changed elsewhere. This is what it holds now.", Kubernetes is gone from the list and Postgres is in it.
7. Close the shepetal window, add a line `Redis` in the editor and save, then open the window again from the 🤫 menu. Expected: Redis is in the list.
8. Click Remove on the OMW row. Expected: it leaves the list, and the file has no omw line. The header comments are unchanged.

### M-STATS-1: your stats (F60)
1. Choose Open shepetal in the 🤫 menu and go to Home. Note the numbers under "Your stats".
2. In TextEdit, hold fn, say "one two three four five" and release. In Notes, dictate a sentence of about ten words. Then tap fn once briefly (too short), and start one more dictation and press Esc (cancelled).
3. Click back into the shepetal window, on Home. Expected: Words went up by the words that were pasted (about 15) in both Last 7 days and All time. Dictations went up by 2: the short tap and the cancelled one do not count. Top apps lists TextEdit and Notes with their words added.
4. Check the math with the numbers shown. Words per minute is about Words divided by Speaking time in minutes. Time saved is Words / 40 minutes minus Speaking time, and never negative.
5. In History, archive the TextEdit row and go back to Home. Expected: the numbers do not change, because archived dictations still count.
6. Optional: run `defaults write io.backant.shepetal typingWpm 60`, then quit and reopen shepetal. Expected: the caption says 60 words per minute and Time saved is lower. Run `defaults delete io.backant.shepetal typingWpm` to reset it.

### M-STREAK-1: streak and milestone notes (F61)
1. Choose Quit shepetal in the 🤫 menu. In Terminal, start shepetal on an empty data dir. A `SHEPETAL_HOME` run is signed out (it uses its own keychain entry), so it is started without the sign-in gate:
   `H=/tmp/shepetal-streak; rm -rf $H; mkdir -p $H; open --env SHEPETAL_HOME=$H --env SHEPETAL_REQUIRE_SIGNIN=0 /Applications/Shepetal.app`
   Choose Open shepetal in the 🤫 menu and go to Home. Expected: there is no Insights section.
2. In TextEdit, hold fn and say "first words". Expected: after the paste, "Your first dictation with shepetal" shows next to 🤫 for about 6 s. Click back into the shepetal window. Expected: Insights appears with "1-day streak" and one filled square, the last one.
3. Choose Quit shepetal. Replace the history with one dictation of 165 words at local noon on each of the 6 days before today (990 words in all), plus one cancelled dictation of 2,000 words yesterday:
   `sqlite3 $H/history.sqlite "DELETE FROM history"; for d in 1 2 3 4 5 6; do sqlite3 $H/history.sqlite "INSERT INTO history(id, created_at, outcome, audio_path, duration_ms, model, raw_text, text, app) VALUES ('seed-$d', strftime('%s','now','localtime','start of day','-$d days','+12 hours','utc'), 'inserted', '', 60000, '', '', replace(printf('%.*c', 82, 'x'), 'x', 'ship it ') || 'done', 'TextEdit')"; done; sqlite3 $H/history.sqlite "INSERT INTO history(id, created_at, outcome, audio_path, duration_ms, model, raw_text, text, app) VALUES ('seed-x', strftime('%s','now','localtime','start of day','-1 days','+13 hours','utc'), 'cancelled', '', 60000, '', '', trim(replace(printf('%.*c', 2000, 'x'), 'x', 'deploy ')), 'Slack')"`
   Then run `open --env SHEPETAL_HOME=$H --env SHEPETAL_REQUIRE_SIGNIN=0 /Applications/Shepetal.app` and open Home. Expected under Insights:
   - "6-day streak";
   - six filled squares ending yesterday, and today's square empty. Hovering it shows today as "DD.MM.YY: 0 words".
   - Busiest hour 12:00–13:00;
   - Top app TextEdit;
   - Most-used word "ship";
   - Favourite phrase "ship it";
   - Words so far 990 · next milestone 1,000. The thousands separator follows your system region, so on a German region it reads 1.000. The same goes for the numbers in step 4.

   The cancelled dictation counts nowhere: there is no Slack and no "deploy", and the 2,000 words are not added. Your stats shows 990 words too.
4. In TextEdit, hold fn and say at least ten words, for example "one more sentence so the streak reaches a full week today". Expected: after the paste, "7-day streak: you dictated every day · 1,000 words dictated so far" shows next to 🤫. Home shows "7-day streak", and today's square is filled.
5. Dictate another sentence. Expected: no note. Then tap fn briefly once, and start a dictation and press Esc. Expected: neither shows a note, and the streak and Words so far do not change.
6. In Settings, untick Milestone notices. Run `sqlite3 $H/history.sqlite "DELETE FROM history WHERE id NOT LIKE 'seed-%'"`, then dictate the ten-word sentence from step 4. Expected: no note, though Home shows "7-day streak" again. Tick Milestone notices, run the same command, and dictate it once more. Expected: the note from step 4 shows again.
7. Choose Quit shepetal. Run `rm -rf /tmp/shepetal-streak` and `open /Applications/Shepetal.app`. Expected: your own history is back, unchanged.

### M-HUB-8: Insights on Home (F62)
1. With your own data dir, dictate "let me know" into Slack (or TextEdit) as three separate dictations. Then dictate one other sentence into Notes.
2. Choose Open shepetal in the 🤫 menu and go to Home. Expected under Insights:
   - Each column is a week that starts on the first weekday of your region. Today's square, the lowest one in the last column, is filled. Hovering it shows today's date as DD.MM.YY and its words.
   - Days you dictated more are darker.
   - Busiest hour is the hour with the most words. Top app is the app with the most words.
   - Most-used word is a real word, never "the", "and", "und" or "ich".
   - Favourite phrase is "let me know", unless your history has another 2 or 3 word phrase used more often.
   - Words so far shows the same total as Your stats › All time › Words, with the next milestone.
3. Hover a square from an earlier day you dictated on. Expected: that day's date and words. A day without dictations shows "0 words".
4. Switch System Settings › Appearance between Light and Dark. Expected: the empty and filled squares stay visible in both.

### M-SHARE-1: share stats card (F118)
1. Dictate a few times in TextEdit. Choose Open shepetal in the 🤫 menu and go to Home. Click **Share stats…** (under Insights).
2. Expected: a sheet with a dark card that shows 🤫 shepetal, your words, words per minute and (if you have one) the day streak, matching Your stats › All time and Insights. It names no model. The caption says nothing is uploaded.
3. Click **Copy**, then paste in Messages (or Notes). Expected: the card appears as an image.
4. Click **Save…** and save to the Desktop. Expected: `shepetal-stats.png`, 1200 × 630 px, opens in Preview.
5. Click **Post…**. Expected: the browser opens an x.com post with the text "I've dictated N words with shepetal at W words per minute…" filled in. Nothing is posted until you send it there. Close the tab.
6. Opening the sheet alone opens no browser and leaves the clipboard unchanged.

### M-NOTICE-1: recent notices on Home (F100)
1. Tap fn once briefly. Expected: "Hold fn to talk · double-tap for hands-free" shows next to 🤫 for about 3 s.
2. Open a TextEdit document and Notes. Click into the TextEdit document, double-tap fn and say "notices check one two". Click into a Notes note, then tap fn once to stop. Expected: nothing is pasted, focus stays on Notes, and "The window changed while you spoke. The text is on the clipboard: press ⌘V to paste it." shows next to 🤫.
3. Tap fn briefly three times, a few seconds apart.
4. Choose Open shepetal in the 🤫 menu, on Home. Expected: under Recent notices, newest first: the short-press hint once (the three taps in step 3 are one row, at the time of the last tap), then the clipboard hint, then the short-press hint from step 1. Each row shows its time as DD.MM.YY HH:MM. No row contains "notices check one two".
5. Leave the window open and tap fn briefly once more. Expected: the list updates within about 1 s.
6. Choose Quit shepetal in the 🤫 menu, start it again, and open Home. Expected: Recent notices says "None yet" (the list is only in memory).

### M-THEME-1: light, dark and auto (F93)
1. In the 🤫 menu choose Open shepetal, and put the window next to System Settings › Appearance.
2. Choose Dark. Expected: the shepetal window turns dark at once, without closing it: background, tabs, lists and buttons. Click through Home, History, Meetings and Settings: all dark, all text readable.
3. Choose Light. Expected: it turns light at once, all text readable. Choose Auto. Expected: it matches the rest of macOS (Finder windows, the menu bar).
4. Repeat 2 and 3 with Shortcuts… (🤫 menu), Permissions… (Settings tab) and What's new… (Home) open, and with the meeting transcript window open after a recorded meeting (M-MTG-1). Expected: each one follows at once.
5. In Light, on a light wallpaper, tap fn briefly. Expected: the short-press hint next to 🤫 is white on a dark plate and readable for its 3 s. If the meeting card ("Meeting detected · …") shows, it is dark in Light too.
6. Expected: there is no theme setting in shepetal. It follows the system on purpose.

### M-NOTE-1: scratchpad notes (F55)
1. Choose Shortcuts… in the 🤫 menu. Expected: an "Open notes" row reading "Not set". Click its Change… and press ⌃⌥N. Expected: the row reads ⌃⌥N.
2. Click into TextEdit and press ⌃⌥N. Expected: shepetal's notes window comes to the front with an empty "Untitled" note, and the cursor is in its text. TextEdit gets no "n". Press ⌃⌥N again. Expected: the same window and the same note, with no second note.
3. Type "Shopping" as the title. Expected: the tab is named Shopping. Click into the text, hold fn and dictate a sentence. Expected: the text lands in the note (rule 8: the note kept focus), and ⌘Z undoes it.
4. Click + in the tab bar, or New note under the list. Expected: a second note opens as a second tab of the same window, and the list shows both. In the list, click the first note. Expected: its tab is selected, with no third tab.
5. In the second note, click the pin. Expected: a Pinned section at the top of the list holds that note, and the other note is under Notes.
6. Click into TextEdit and choose Notes… in the 🤫 menu. Expected: the notes window comes back to the front.
7. Type a word into a note and, within a second, choose Quit shepetal in the 🤫 menu. Open shepetal again and press ⌃⌥N. Expected: both notes are there, the pinned one first, and the last word was saved. `ls -l ~/Library/Application\ Support/Shepetal/notes.sqlite` shows `-rw-------`.
8. Click the trash on a note and confirm. Expected: its tab closes and the note is gone from the list, and still gone after a relaunch.
9. Shortcuts… › Reset to defaults. Expected: Open notes reads "Not set", and ⌃⌥N in TextEdit does nothing in shepetal.
(The store, the order, the 0600 file, tabs, pinning, autosave and the editing keys are covered by `NotesTests`, `NotesWindowTests` and `ShortcutsTests.testOpenNotesFiresOnlyOnceBoundAndIsKept`. This step checks real windows, real keys and a real dictation.)

### M-CTX-1: app and page URL
1. Dictate into TextEdit, into a text field in Safari, and into a text field in Chrome (for example a GitHub comment box).
2. Open History. Expected: the rows show "TextEdit", "Safari · github.com" and "Google Chrome · github.com". The URL is stored only in `history.sqlite` (`sqlite3 … 'select app, bundle_id, url from history order by created_at desc limit 3'`).
3. If a Chrome row has no host, note it on the PR: Chrome had no accessibility tree for the page (see the `ponytail:` note in `Sources/Shepetal/AppContext.swift`).
4. With Chrome in front on a heavy page (a long GitHub pull request), tap fn quickly five times, waiting 2 s after each tap. Expected: each tap shows the short-press hint and nothing is inserted. The page-URL lookup runs off the main thread, so a slow page must not turn a tap into a hold.

### M-CTX-2: the text around the cursor reaches the cleanup model (F24)
Setup: the cleanup model is downloaded, and Home's Cleanup line says "On". Open shepetal > Settings: "Use the text around the cursor to clean up dictation" is on (the default). Turn it off for step 2.
1. In TextEdit, make a new document and type "Packing list:", Return, "1. Passport", Return, "2. Charger", Return. Leave the cursor on the empty third line.
2. Hold fn and say "number three, headphones". Expected with the setting off: the line is not numbered (for example "Number three, headphones.").
3. Undo it (⌘Z), turn the setting on, click back to the same place in TextEdit, and dictate the same. Expected: "3. Headphones".
4. Press Return twice to leave the list, type "To: Ksenia", then press Return twice. With the setting on, dictate "tell ksenia the draft is ready". Expected: "Tell Ksenia the draft is ready.", with no other word from the field. Turn the setting off and dictate it again. Expected: the same words; only case or punctuation may differ. If speech-to-text heard another name (for example "Xenia"), the field does not change it, because only case, punctuation and list numbers may change. Note what you got.
5. Press Return twice, type "Can you send me the address of the venue?", then press Return twice. With the setting on, dictate "yes I will send it tonight". Expected: only your words ("Yes, I will send it tonight."), with no answer and no words from the question.
6. Open History. Expected: the rows hold only what you dictated, nothing from the field. In Console (filter "shepetal"), the "context:" lines show role, length and selection only, never the field's text.
7. With the setting on, dictate "send it to John, I mean Jane" and press Esc right after release. Expected, as with the setting off: if Esc came before the paste, nothing is pasted and History marks the row cancelled.

### M-MTG-1: Zoom call, detected, recorded after one click, and transcribed (rule 7)
Setup: quit Shepetal, run `scripts/make-app.sh --install` from main, and open `/Applications/Shepetal.app`. You need a second person or a second device (a phone in the same Zoom meeting, speaker on, away from the Mac's mic). Open shepetal > Settings: "Always record meetings automatically" is off (the default).
1. Start or join a Zoom meeting in the zoom.us app, with your mic unmuted. Click into Zoom's chat box.
2. Expected about 5 s after Zoom opens the mic: a small card just above the 🤫 in the bottom-left corner says "Meeting detected · zoom.us", with Record and Not now. Nothing records yet: 🤫 has no red ring, the menu bar shows "🤫", and the 🤫 menu shows "Record meeting".
3. Click Record. Expected: the card goes away, and typing still goes into Zoom's chat box (the click did not take focus or bring Shepetal forward). "Meeting detected · recording" shows next to 🤫, 🤫 gets a red ring that stays for the whole meeting, the menu bar shows "🤫●", and the 🤫 menu shows "Stop meeting recording". The first time, macOS asks whether Shepetal may record system audio: allow it. If the hint says "… mic only (turn on System Audio Recording)", add Shepetal under System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only, then leave and rejoin the call.
4. Open 🤫 > Open shepetal > Meetings. Expected: a "zoom.us" meeting at the top, still running. Within about a minute its transcript fills in, with your lines labelled Me and the other side's labelled Others.
5. Say "I will send the slides by Friday." Have the other side say "I will review the budget tomorrow."
6. Leave the meeting. Expected within about 5 s: "Meeting recording saved", then "Meeting notes ready · open Shepetal → Meetings", the red ring goes away, and the menu bar goes back to "🤫". The meeting's Summary lists the action items "Me: send the slides (Friday)" and "Others: review the budget (tomorrow)" (the wording may differ slightly).
7. Type `budget` in the Meetings search. Expected: the meeting is found. Click Copy summary and paste in TextEdit: the summary is pasted, without the transcript. Export Markdown writes a `.md` file where you choose.
8. Run `ls -la ~/Library/Application\ Support/Shepetal/meetings/*/`. Expected: the meeting's folder is `drwx------` and holds `Me.wav` and `Others.wav`, both `-rw-------`. Open them in QuickTime: Me is your mic, Others is the call audio.
9. Do steps 1 to 6 again without headphones, with the call on the MacBook's own speakers at normal volume. The mic hears the other side here too, and Me.wav keeps that echo (the audio is kept as recorded). Expected: the transcript has no Others line a second time under Me, and the summary has "Others: review the budget (tomorrow)" once, with no second copy under Me. Short replies of yours said over the other side ("yes, that works") stay under Me.
10. Not now: join a Zoom meeting and click Not now on the card. Expected: the card goes, nothing records (no red ring, "🤫" in the menu bar, "Record meeting" in the menu), no new meeting appears under Meetings, and the card does not come back while you stay in that meeting. Leave it.
11. Timeout: join again and leave the card alone. Expected: it goes away by itself after about 20 s and nothing records. 🤫 > Record meeting still records the rest of this meeting by hand (listed as "Manual"); stop it from the menu.
12. Always record: in Open shepetal > Settings, turn on "Always record meetings automatically". Join a Zoom meeting. Expected: no card; about 5 s after Zoom opens the mic, "Meeting detected · recording" next to 🤫, the red ring, "🤫●", and "Stop meeting recording" in the menu. Stop meeting recording ends it. Turn the setting off again.
13. Silence end (F67): run `defaults write io.backant.shepetal meeting.silenceEnd 40`, then quit shepetal from the 🤫 menu and open it again. Wait until a dictation works (the speech model is loaded). Join a Zoom meeting and click Record on the card. Then everyone stays silent: no one speaks on either side, and no one types. The model can write typing or room noise as words, such as "(keyboard clicking)", "*typing*" or "Thank you.", and words keep the meeting going. If it does not end, open the meeting in Meetings and write down any line in the transcript from the silent part: that line kept it going. Expected within about 70 s, while you are still in the call: "Meeting ended · no one spoke for 40 s" shows next to 🤫, then "Meeting notes ready · open Shepetal → Meetings". The red ring goes away, the menu bar shows "🤫", the menu shows "Record meeting", and the card does not come back for this call. The meeting is listed in Meetings, and its folder still holds Me.wav and Others.wav. Next, choose 🤫 > Record meeting and talk with the other side for 2 min, never silent for 40 s. Expected: it keeps recording until you choose Stop meeting recording, and the hint is "Meeting recording saved". Last, run `defaults delete io.backant.shepetal meeting.silenceEnd` and restart shepetal (the default is 2 min again).

### M-MTG-2: Google Meet in a browser
Setup: as in M-MTG-1. Shepetal needs no Screen Recording access; if you added it for an older build, you can leave it or remove it.
1. Join a Google Meet call in Chrome with the mic on. Expected about 5 s after Chrome opens the mic: the card says "Meeting detected · Google Chrome". Click Record: the meeting is listed as "Google Chrome". Repeat steps 4 to 8 of M-MTG-1.
2. Switch to another tab or window for a minute during the call. Expected: no event, the recording goes on.
3. Do step 1 in Safari. Expected: "Meeting detected · Safari" (Safari's mic is held by its WebKit GPU process, which is named after Safari).
4. Camera only: mute the mic before you join, with the camera on. Expected: "Meeting detected · Camera".

### M-MTG-3: dictation during a meeting
1. During a recorded Zoom call, click into TextEdit, hold fn, say a sentence, and release. Expected: the sentence is inserted as usual, no second meeting starts or is offered, and the ring around 🤫 stays red throughout.
2. Expected afterwards: the meeting's transcript has the sentence under Me, since the meeting records the mic too.

### M-MTG-4: quit during a meeting
1. Start a meeting recording, talk for a minute, then quit Shepetal from the 🤫 menu.
2. Expected: both WAVs are kept and play to the end. The meeting is listed as ended, with the transcript up to the last 30 s live pass. It gets no summary: a meeting cut off by quitting is not transcribed again at the next launch.

### M-MTG-5: killed during a meeting (#100)
1. Start a meeting recording and talk for about 20 s. Then, in Terminal, run `pkill -9 -x Shepetal`, as a crash would end it.
2. Run `afinfo ~/Library/Application\ Support/Shepetal/meetings/<newest>/Me.wav` (and `Others.wav` if it is there). Expected: `estimated duration` is about 20 s, not 0. Both files play in QuickTime up to the kill.

### M-MTG-6: mic only, without System Audio Recording (F65)
Setup: as in M-MTG-1, but wear headphones so the Mac's mic does not hear the other side.
1. In System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only, turn Shepetal off (switch it off, do not remove it). Quit Shepetal and open it again.
2. Join a Zoom meeting and click Record on the card. Expected: macOS does not ask about system audio. "Meeting detected · recording mic only (turn on System Audio Recording)" shows next to 🤫, and the red ring, "🤫●" and "Stop meeting recording" show as in M-MTG-1 step 3.
3. Say a sentence, have the other side say one, then leave the meeting. Expected within about 5 s: "Meeting recording saved", then "Meeting notes ready · open Shepetal → Meetings". The meeting's transcript has only Me lines, and none of what the other side said.
4. Run `ls -la ~/Library/Application\ Support/Shepetal/meetings/<newest>/`. Expected: only `Me.wav` (`-rw-------`), no `Others.wav`.
5. Turn Shepetal back on under System Audio Recording Only, quit and reopen Shepetal, and record another meeting. Expected: the hint has no "mic only", and the new folder holds both `Me.wav` and `Others.wav`.

### M-MTG-7: Microsoft Teams, a Slack huddle and the camera alone (F66)
Setup: as in M-MTG-1. No step needs Screen Recording access.
1. Join a call in the Microsoft Teams app with the mic on. Expected about 5 s after Teams opens the mic: the card says "Meeting detected · Microsoft Teams". Click Record, talk for at least 15 s (no meeting ends sooner), then leave the call. Expected about 4 s later: "Meeting recording saved", the red ring goes away, and Meetings lists the meeting as "Microsoft Teams".
2. In the Slack app, start a huddle with someone. Expected about 5 s after the huddle opens the mic: "Meeting detected · Slack". Click Record, talk for at least 15 s, then leave the huddle. Expected about 4 s after Slack lets go of the mic: "Meeting recording saved", and Meetings lists the meeting as "Slack".
3. Not now with video: join a Zoom call with the camera on and click Not now. Mute the mic and stay for a minute. Expected: no new card while the camera is on. Leave the call, wait 5 s, and open Photo Booth. Expected about 5 s later: "Meeting detected · Camera". Click Not now and quit Photo Booth.
4. Any mic use counts: record an audio clip in a Slack message box, without a huddle. Expected: a card about 5 s after the clip starts if it runs that long. Click Not now: nothing records.

### M-MTG-8: the transcript window after a meeting (F69, F120)
Setup: as in M-MTG-1. Before the meeting, select the word `canary` in TextEdit and press Cmd+C.
1. Record a Zoom meeting and say a few sentences, as in M-MTG-1 steps 1 to 5. Leave the meeting, click into TextEdit at once, and keep typing.
2. Expected a few seconds after "Meeting recording saved": a "Meeting transcript" window comes to the front. Its first line reads "Zoom · DD.MM.YY HH:MM · N min" (for example "Zoom · 21.10.26 15:00 · 12 min"). Below that is the whole transcript, with each Me and Others line and its time, and "Summarizing…" above it. Your typing keeps landing in TextEdit: the window did not take the keyboard. There is no sound, and no model name appears anywhere. Cmd+V in TextEdit still pastes `canary`, because the window never writes the clipboard by itself.
3. Expected: "Summarizing…" is replaced by the sections the summary has, under the headings Overview, Key points, Decisions and Action items, as in the Meetings tab. Copy summary is greyed out until then.
4. Click Copy transcript. Expected: "Transcript copied" appears next to the first line, with no sound. Cmd+V in TextEdit pastes the first line, an empty line, then one line per segment, such as `Me (0:05): I will send the slides by Friday.`, with no Markdown. Click Copy summary and paste. Expected: the summary, without the transcript, with the same sections as the window shows. Its first line is `# Zoom · DD.MM.YY HH:MM · N min`, the window's first line.
5. Click into the window, select a few words in one line, and press Cmd+C. Paste. Expected: only those words. Turn Caps Lock on, select other words, and press Cmd+C again. Expected: those words paste, and there is no beep. If a Russian keyboard layout is installed, switch to it and repeat: the same.
6. Click Open in Meetings. Expected: the Shepetal window opens on the Meetings tab, with this meeting open. Its Copy transcript button, next to Copy summary, copies the same text as in step 4.
7. Record a second meeting and end it while the window is still open. Expected: the same window now shows the second meeting, and no second window opens. Close the window: it stays closed until the next meeting ends.
8. No speech: choose 🤫 > Record meeting, stay silent for 20 s, then choose Stop meeting recording. Expected: the window says "No speech was recorded". The first line has no app name ("DD.MM.YY HH:MM · < 1 min"). Copy transcript and Copy summary are greyed out, and Open in Meetings opens the meeting.
8a. A decision and nothing else: choose 🤫 > Record meeting and say only "We decided to ship on Friday.", "Okay." and "Sounds good.", then stop it. Expected: "Summarizing…" goes away and the window shows Decisions with "We decided to ship on Friday.". Copy summary pastes that decision under `## Decisions`. Record another meeting by hand and say only "Okay.". Expected: "Summarizing…" is replaced by "No summary for this meeting", and Copy summary stays greyed out.
9. Choose 🤫 > Record meeting and say a sentence. Put Safari in full screen and click into its address bar. Then choose 🤫 > Stop meeting recording. Expected: the window shows over full-screen Safari, and typing still goes into the address bar.
10. Close the window. Open 🤫 > Past meetings. Expected: the meetings you just recorded, newest first, each as "Zoom · DD.MM.YY HH:MM · N min" (up to 8, none still recording). Choose the first: the same "Meeting transcript" window shows it, again without taking the keyboard.
11. After Settings > Recordings > Delete recordings after 24 hours has removed a meeting's audio (as in M-HUB-3 step 2, with `touch -t` on its folder), open that meeting in the Meetings tab. Expected: its transcript and summary are still there, and Copy transcript still works.

### M-MTG-9: notes during a meeting (F71)
Setup: as in M-MTG-1.
1. Record a Zoom meeting as in M-MTG-1 steps 1 to 3. While it records, choose 🤫 > Open shepetal > Meetings, open the live meeting and click Notes. Type, one per line: `Pricing page needs a rewrite before launch`, `TODO: draft the FAQ`, `Send the deck to Kate by Friday` and `budget`. Expected: the text stays as typed, and the recording goes on (the ring stays red). Click back into Zoom and say a few sentences, among them "We will rewrite the pricing page before the launch." Expected: the call is not disturbed. There is no sound and no model name.
2. Quit shepetal from the 🤫 menu during a second recorded meeting after typing a note, then open it again. Expected: the note is still in that meeting's Notes pane.
3. Leave the first meeting. Expected, once the "Meeting transcript" window shows the summary: "Your notes" comes first, with the four lines. Under Action items, "draft the FAQ" (Me) and "Send the deck to Kate" (Me, Friday) come first. No key point repeats the pricing-page note. The window still did not take the keyboard.
4. In the Meetings tab, open the meeting's Notes, add the line `I'll book the retro tomorrow`, then click Summary. Expected: "book the retro" (Me, tomorrow) is now among the action items, without recording again.
5. Click Copy summary and paste into TextEdit. Expected: `## Your notes` comes right after the first line, with each note as `- ` plus the line, and before `## Overview`. Click Export Markdown…, save, and open the file. Expected: the same notes section, with the transcript at the end.
6. Type `Kate` in the Meetings search field. Expected: the meeting is listed, found by its notes.

### M-MTG-12: folders and search in Meetings (F78, F120)
Setup: as in M-MTG-1, with at least three recorded meetings, one of which said "budget" (M-MTG-1 step 5). Steps 1 to 7 are folders (F78), steps 8 to 13 search (F120).
1. Open shepetal > Meetings. Expected: an All | Folders switch above the search field. All is selected and lists every meeting newest first, as before.
2. Click Folders. Expected: "No folders yet" and a New folder button. Click New folder, type `Clients` and click Create. Expected: Clients opens, and the detail says "No meetings in this folder".
3. Click All. Right-click the newest meeting > Add to folder > Clients, then do the same for the oldest one. Expected: each one's Add to folder menu shows Clients checked. Click Folders. Expected: "Clients (2)" lists those two, newest first.
4. Click the new-folder button (the folder with a +) and make `Launch`. In All, add the oldest meeting to Launch too. Expected: its Add to folder menu has both folders checked.
5. With Launch open in Folders, use ⋯ > Rename… to rename it `Beta launch`. Then use ⋯ > Delete…. Expected: the dialog says its meetings are not deleted. Confirm. Expected: Clients opens, and the oldest meeting is still in Clients and in All.
6. Quit shepetal from the 🤫 menu and open it again. Expected: Clients still holds its two meetings.
7. In All, right-click one of Clients' meetings > Add to folder > Clients, to uncheck it. Expected: it leaves Clients and stays in All.
Search (F120), with Clients holding one or more meetings and some meetings outside it:
8. In All, type `budget` quickly. Expected: the list updates once, shortly after you stop typing, not after each letter. Under each result is a grey line with the words around "budget", in bold, cut at whole words with "…".
9. Expected: the meeting where "budget" matters most (for example, in its summary or several times) is first. Equal matches are newest first.
10. Type a 2-letter word from a transcript, for example `Q3`. Expected: found, with the text around it under the row.
11. Type `zoom`. Expected: the zoom.us meetings are listed, with no grey line, because the match is the app name the row already shows.
12. Click Folders, open Clients, and type `budget`. Expected: only Clients' meetings that match are listed, and a matching meeting outside Clients is not. Clear the search. Expected: all of Clients' meetings are listed again.
13. With Clients open, open the transcript window of a meeting that is not in Clients (🤫 > Past meetings) and click Open in Meetings. Expected: Meetings switches to All with the search cleared and opens that meeting.

### M-EXP-1: export my data (F64)
1. Have a few dictations (archive one in History, and dictate one sentence with a comma and a quote in it), one meeting with a summary, and a word in Settings › Dictionary…. In Settings, click "Export my data…". Expected: a folder panel with an Export button. Click Cancel. Expected: nothing is written anywhere.
2. Click it again, pick Desktop and click Export. Expected: Finder shows a selected folder "shepetal-export-<yyyy-MM-dd>", and the caption under the button reads "Exported to …". The folder has history.json, history.csv, dictionary.json, dictionary.txt, meetings.json, and meetings/ with one .md per meeting. In Terminal, `ls -la ~/Desktop/shepetal-export-*/ ~/Desktop/shepetal-export-*/meetings`: the folders are `drwx------` and every file is `-rw-------`.
3. Open history.csv in Numbers. Expected: one row per dictation, newest first, including the archived one (archived = yes). Dates read DD.MM.YY HH:MM:SS, and the sentence with the comma and the quote stays in one cell.
4. Open the meeting's .md in TextEdit. Expected: the same text as that meeting's Export button in the Meetings tab gives: headline, overview, decisions, action items and transcript.
5. Click "Export my data…" again and pick Desktop. Expected: a second folder "…-2", with the first one unchanged.
(Owner-only files, the JSON round trip, CSV escaping, the empty case and failure cleanup are covered by `DataExportTests`. This step checks the panel, Finder and Numbers.)

### M-MCP-1: AI apps read meetings and dictations (F86)
1. Have at least one recorded meeting with a summary (see the meeting steps) and a few dictations. Choose Open shepetal in the 🤫 menu, then Settings. Expected: "Let AI apps read my meetings and dictations" is off, with a caption under it, and a "Copy setup for AI apps" button.
2. Click "Copy setup for AI apps". Expected: the button reads "Copied: paste it into the AI app's MCP settings". Cmd+V in TextEdit gives a JSON block: `"mcpServers"` › `"shepetal"` with `"command": "/Applications/Shepetal.app/Contents/MacOS/Shepetal"` and `"args": ["--mcp"]`.
3. Claude Desktop: Settings › Developer › Edit Config, then merge the `"shepetal"` entry into `"mcpServers"` in `claude_desktop_config.json`. (Cursor: add it to `~/.cursor/mcp.json`.) Quit and reopen the AI app. Expected: shepetal shows as a connected MCP server with the tools list_meetings, search_meetings, get_meeting and search_dictations. No second 🤫, Dock icon or window appears.
4. With the toggle still off, ask "What did we decide in my last meeting?". Expected: the answer says shepetal is not sharing and tells you to turn on "Let AI apps read my meetings and dictations" in shepetal Settings. No meeting text appears.
5. Turn the toggle on, without restarting either app, and ask again. Expected: the AI app calls list_meetings, then get_meeting, and the answer quotes the overview or decisions of your newest meeting, the same as shepetal's Meetings tab shows.
6. Ask "Find my dictation about <a word you dictated earlier>". Expected: it quotes that dictation with its DD.MM.YY date and app.
7. Ask it to delete that meeting. Expected: it has no tool for that, and the meeting is still in the Meetings tab.
8. Turn the toggle off and ask once more. Expected: refused, as in step 4.
(The protocol shape, the opt-in, the read-only stores and the clean stdout are covered by `MCPTests` and `MCPWiringTests`. This step checks a real AI app.)

### M-ACC-1: first launch, sign-in and the free trial
Needs shepetal.backant.io live, and a build that requires sign-in: the release package, `REQUIRE_SIGNIN=1 scripts/make-app.sh --install` (the "Built" line ends with "sign-in required"), or any build started with `SHEPETAL_REQUIRE_SIGNIN=1 dist/Shepetal.app/Contents/MacOS/Shepetal`. Add `SHEPETAL_ACCOUNT_URL=http://localhost:3000` to test against a local copy of the site.
0. Without `ShepetalRequiresSignIn` or the variable (a plain `scripts/make-app.sh` build), signed out: expected the menu still offers Sign in to start your free trial…, but no sign-in hint shows at launch, no window opens by itself, and fn dictates normally.
1. Sign out first if this Mac was signed in (Open shepetal > Home > Sign out). Quit and open Shepetal. Expected: next to 🤫 "Sign in with Google to start your free 30-day trial" for a few seconds, and the Shepetal window opens by itself on Home. Its first section, Account, says "Not signed in" with a large "Sign in with Google to start your free 30-day trial" button. The top of the 🤫 menu shows "Sign in to start your free trial…". Close the window and wait two minutes: it does not open again by itself.
2. Hold fn in TextEdit, then let go. Expected: nothing is recorded or inserted, no new file appears in `~/Library/Application Support/Shepetal/audio`, the menu-bar mic indicator (orange dot) never shows, the hint "Sign in with Google to start your free 30-day trial" shows next to 🤫 with no error ring and no mic message, and when fn is let go the Shepetal window comes to the front on Home. Click back into TextEdit and press fn+Delete, fn+← and fn+→ a few times: expected they work in TextEdit (forward delete, Home, End) and the window never comes to the front.
3. Choose Sign in to start your free trial… in the 🤫 menu. Expected: a sign-in sheet opens shepetal.backant.io and goes to Google; if the browser is already signed in to Google, one click picks the account. Nothing to type. Home says "Signing in with Google…" and the menu has Cancel sign-in. Expected: after the sheet closes, within a few seconds the top of Home shows "Signed in as <your email> · Trial, 30 days left", Get Shepetal for $4.99 (lifetime, updates included) and Sign out, and the 🤫 menu has no account item at all (Get shepetal for $4.99… shows there from 7 days left). Quit and reopen Shepetal: the window does not open by itself. Run `security find-generic-password -s io.backant.shepetal.account` in Terminal. Expected: an item exists (do not print its secret).
4. Hold fn and dictate into TextEdit. Expected: it works as in M-FN-1.
4a. Sign out on Home, choose Sign in to start your free trial… again and close the sheet with Cancel. Expected: no error, Home is back to "Not signed in" and the menu to Sign in to start your free trial…. Sign in again.
5. Quit and reopen Shepetal with Wi-Fi off. Expected: the trial line is unchanged and dictation still works (7-day offline grace). Turn Wi-Fi back on.

### M-ACC-2: buy, lifetime, sign out
1. On a test account with 7 days or less left, open the 🤫 menu. Expected: Get shepetal for $4.99… at the top. Choose it. Expected: Stripe Checkout opens in the browser. Pay with a Stripe test card on a test deployment. Expected: within about a minute of paying, Home says "Signed in as <email> · Yours forever", and neither Home nor the menu has a Buy item.
2. On the site, end the trial of a test account (or wait for it). Reopen Shepetal. Expected: once the license check answers, the window opens on Home with "Signed in as <email> · Trial ended" and Get Shepetal for $4.99 (once per launch), and the 🤫 menu has Get shepetal for $4.99… at the top; holding fn shows "Trial ended: get Shepetal for $4.99", opens Home when fn is let go and records nothing.
3. Choose Sign out on Home. Expected: "Not signed in", fn shows the sign-in hint, and `security find-generic-password -s io.backant.shepetal.account` finds nothing.
4. While dictating a long hands-free note, watch Little Snitch or `nettop -p shepetal`: expected no connection during the dictation.

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
4. Tap the mic on the keyboard. Expected: the island shows a blue ring and "Transcribing", then 🤫 with no ring and "Ready" once the text is inserted (the mic stays open, I-OPEN-1). With "Keep the microphone open" set to "Close after each dictation", the Live Activity ends instead.
5. Start a Timer in the Clock app, then start a dictation. With two Live Activities, iOS shows one of them as a small circle at the edge of the island. Expected: when that circle is Shepetal's, it shows 🤫 with its ring.
6. Tap the mic and stop it at once (I-SHORT-1). Expected: the island shows a yellow ring and "Not inserted" for about 4 s, then "Ready" again. With "Close after each dictation", it ends after the 4 s instead.
7. Turn off Settings > Shepetal > Live Activities and run I-DICT-1 again. Expected: no Live Activity, and dictation works the same.
8. Start a dictation, go back, then force-quit Shepetal from the app switcher. Lock the iPhone. Expected: the Live Activity stays at most about 6 minutes on "Listening" with a red ring, then shows "Stopped" without a ring. Opening Shepetal removes it.

### I-OPEN-1: the next dictation starts without opening Shepetal
1. In Shepetal, check that "Keep the microphone open" is "5 minutes" (the default). Run I-DICT-1 once.
2. Expected: after the text is inserted, the orange mic dot stays on, the Live Activity shows 🤫 and "Ready", and Shepetal (if you switch to it) says the microphone stays open and shows "Turn off the microphone".
3. Back in Notes, play music in another app, then tap the mic within 5 minutes. Expected: Shepetal does NOT open. The keyboard shows "Starting...", then a red ring and "Listening. Tap the mic to finish." within about a second. Say a sentence, tap the mic. Expected: only that sentence is inserted, nothing said or played between the two dictations, and the music kept playing.
4. Wait 5 minutes without dictating. Expected: the orange mic dot goes off and the Live Activity ends. Tap the mic: Shepetal opens again, as in I-DICT-1.
5. Set "Keep the microphone open" to "1 hour" (the longest choice), dictate once, then tap "Turn off the microphone" in Shepetal. Expected: the mic dot goes off and the Live Activity ends at once.
6. Set it to "Close after each dictation" and dictate. Expected: the mic dot goes off as soon as the text is inserted, and every dictation opens Shepetal.
7. With the mic open (step 2), force-quit Shepetal from the app switcher and lock the iPhone. Expected: within about 1.5 minutes the Live Activity stops saying "Ready" and shows "Stopped" with no ring. Unlock, go back to Notes and tap the mic. Expected: after about 1.5 s the keyboard says "Opening Shepetal..." and Shepetal opens, as in I-DICT-1.
8. With the mic open, take a phone call or ask Siri something. Expected: the mic dot goes off and the next tap opens Shepetal.
9. Where your other audio plays while the mic is open: play music on the loudspeaker (no headphones), then dictate once so the mic stays open. Expected: the music keeps playing from the loudspeaker, not the earpiece, at the same volume and quality for the whole open window. Repeat with AirPods connected. Expected: the music stays on the AirPods in normal quality (not the thin call sound). If either moves or changes, report it: the audio session options in `EngineMic.start` need another look.

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

### I-FIELD-2: two fields the keyboard might report as one
The only field signal a keyboard gets is `documentIdentifier`. This step checks that two different fields never share one; if they did, text would go into the wrong field.
1. In Safari, open a page with two text inputs on it (for example a sign-up form with name and email). Tap the first input, start a dictation, go back and say a sentence.
2. Tap the second input on the same page, bring up the Shepetal keyboard and tap the mic.
3. Expected: nothing is inserted in the second input, and the clipboard hint from I-FIELD-1 shows. Paste in the second input to clear the clipboard check.
4. Repeat with Messages: start in one conversation, then open a different conversation and stop there. Expected: the same.
5. If either case inserts the text into the second field, write it down and do not confirm iPhone F19: the identifier alone is not enough and a second field signal is needed.

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

The Mac `meeting/` CLI on its own. The Mac app uses the same detector and capture (M-MTG-1 to M-MTG-7). Build it with `cd meeting && swift build`, and run the commands from `meeting/`. Expected output lines are quoted as the CLI prints them.

### MEET-1: probe
1. Quit every app that uses the mic or a camera. Run `.build/debug/shepetal-meeting probe`.
2. Expected: `no process is using the mic`, `camera in use: no` and `meeting now: none`. It needs no permission and shows no prompt.
3. Join a Zoom call and run `probe` again. Expected: a `mic` line with a bundle id that starts with `us.zoom.`, the app `zoom.us` and a pid, then `meeting now: zoom.us`. With the camera on, `camera in use: yes`. No line has a window title or a URL.

### MEET-2: watch a Zoom call
1. Run `START_AFTER=2 END_AFTER=3 .build/debug/shepetal-meeting watch` (the defaults are 5 s and 4 s).
2. Join a real Zoom call, or a test call at https://zoom.us/test. Expected: about 2 s after Zoom takes the mic, `started(app: "zoom.us")`.
3. During the call, switch your default mic or output, for example to AirPods. Expected: no event.
4. Stay in the call for at least 15 s (no meeting ends sooner), then leave it. Expected: about 3 s later, `ended(app: "zoom.us")`.

### MEET-3: watch a Google Meet call
1. Run `watch` as in MEET-2, with no Screen Recording access for your terminal, and join a Google Meet call in Chrome. Expected: `started(app: "Google Chrome")`.
2. Switch to another tab for a minute and back. Expected: no event.
3. Close the Meet tab. Expected: about 3 s later, `ended(app: "Google Chrome")`.

### MEET-4: shepetal's own dictation does not count
1. Start `watch` with no call.
2. Dictate with the shepetal Mac app for about 10 s.
3. Expected: no event.

### MEET-5: camera alone
1. With `watch` running, open Photo Booth. Expected: after the start delay, `started(app: "Camera")`, and macOS asks your terminal for no camera access.
2. Quit Photo Booth. Expected: `ended(app: "Camera")` once 15 s have passed since the start.

### MEET-6: record a call
1. During a real Zoom or Meet call where someone else talks, run `.build/debug/shepetal-meeting record 15`.
2. The first run, macOS asks for microphone and "System Audio Recording Only" access for your terminal. Allow both and run it again.
3. Expected: `saved /Users/<you>/Library/Application Support/shepetal/meetings/<time>/Me.wav and Others.wav` and exit code 0. On failure it prints `record failed: <reason>` and exits 1.
4. Play both files. Expected: `Me.wav` holds your voice, `Others.wav` the other people in the call.
5. Run `ls -la` on the meeting folder and its parent. Expected: `drwx------` on the folder, `-rw-------` on both files.

## Linux

Setup: a real Ubuntu 24.04 desktop, not a VM without a keyboard of its own. Log in to each session from the gear at the bottom right of the login screen: "Ubuntu" is GNOME on Wayland (the default), "Ubuntu on Xorg" is X11, and "Plasma (Wayland)" is KDE once `sudo apt install kde-plasma-desktop` is installed (keep gdm3 when asked). `echo $XDG_SESSION_TYPE $XDG_CURRENT_DESKTOP` tells you which one you are in. The key, audio and dictionary steps (L-FN, L-SC, L-AUD, L-MIC, L-VOC) behave the same in every session because evdev sits below the display server, so run them once. The L-INS, L-FOC and L-IND steps run once per session.

What is not on main yet, so not tested here: history (#67), the 24 h retention setting (for meeting audio too, #141), and a live meeting transcript, meeting summaries and a meeting state in 🤫. Keep the terminal that runs `shepetal daemon` visible: 🤫 shows only a few words, and the full hints and errors go to its stderr.

The automated part of every step runs with the Docker command in `linux/README.md` (`cargo test`). Test names below are the `#[test]` functions under `linux/src/`.

### L-SETUP-1: build, install and the speech model
1. `sudo apt install git cargo pipewire-bin wtype xdotool ydotool wl-clipboard xclip file`
2. `git clone https://github.com/backant-io/shepetal && cd shepetal/linux && cargo build --release && sudo install target/release/shepetal /usr/local/bin/`. Expected: the build ends with `Finished` (Ubuntu's cargo 1.75 reads the version 3 `Cargo.lock`).
3. Install the runner and the model into `~/.local/share/shepetal/` (CPU machines; for CUDA or Vulkan see docs/linux.md, "Manual test steps", step 2):
   ```sh
   mkdir -p ~/.local/share/shepetal && cd ~/.local/share/shepetal
   curl -L https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-linux-x64-shared.tar.bz2 | tar xj
   curl -L https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2 | tar xj
   echo 'PATH="$HOME/.local/share/shepetal/sherpa-onnx-v1.13.8-linux-x64-shared/bin:$PATH"' >> ~/.profile
   ```
   Log out and back in.
4. `cd ~/.local/share/shepetal/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8 && sherpa-onnx-offline --encoder=encoder.int8.onnx --decoder=decoder.int8.onnx --joiner=joiner.int8.onnx --tokens=tokens.txt --model-type=nemo_transducer test_wavs/en.wav` (use any file in `test_wavs/`). Expected: a JSON line on stdout whose `text` matches the clip.
(Automated: `transcribe_runs_the_engine_the_tier_table_picked`, `whisper_markers_are_dropped_and_other_text_kept`, and the model choice tests `cpu_runs_parakeet_v3_never_a_small_whisper`, `low_end_cpu_falls_back_to_parakeet_110m`, `cuda_runs_parakeet_v3_and_beats_vulkan`, `vulkan_runs_whisper_turbo_q5`, `gpu_with_too_little_ram_falls_back_to_cpu`.)

### L-SETUP-2: the input group
1. Check `id -nG | tr ' ' '\n' | grep -x input`. If it prints nothing, you are not in the group yet: run `SHEPETAL_KEY=rightalt shepetal daemon` (any key your keyboard has, so the fn check passes). Expected: it exits with ``shepetal: cannot read any /dev/input/event*: run `sudo usermod -aG input $USER` and log in again``, and `echo $?` prints 1.
2. `sudo usermod -aG input $USER`, then log out and back in (a new terminal is not enough).
3. Run the command from step 1 again. Expected: `shepetal: hold rightalt to talk, double-tap for hands-free. keyboards /dev/input/eventN (…), model …, insert …` and it keeps running. Stop it with Ctrl+C.

### L-SETUP-3: `shepetal probe` in each session
1. In GNOME Wayland run `shepetal probe`. Expected lines:
   - `hardware:` RAM and cores match `free -g` (rounded up) and `nproc`. `cuda=true` only with `/dev/nvidia0`; `vulkan=true` when `/usr/share/vulkan/icd.d` has a file (Mesa's lavapipe counts too, #46).
   - `model:` on a machine without a GPU and with at least 4 GB: `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8 (SherpaTransducer) on cpu (/home/<you>/.local/share/shepetal/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8)`.
   - `session:   "wayland" desktop "ubuntu:GNOME"` and `insert:    Some(Ydotool)`.
   - one `fn key:` line (L-KEY-1, L-KEY-2), a `mic user:` line per app recording the mic, and `system audio: Some("<sink>.monitor")` where `<sink>` is what `pactl get-default-sink` prints.
2. In "Ubuntu on Xorg": expected `session:   "x11" desktop "ubuntu:GNOME"` and `insert:    Some(Xdotool)`.
3. In Plasma (Wayland): expected `session:   "wayland" desktop "KDE"` and `insert:    Some(Wtype)`.
(Automated: `session_type_picks_native_typer`, `gnome_wayland_skips_wtype`, `ydotool_then_clipboard_are_fallbacks`; `probe` itself runs on the fixture in the Docker command.)

### L-SETUP-4: ydotoold (GNOME Wayland)
1. Let your user open `/dev/uinput`: `echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/80-uinput.rules`, then `sudo modprobe uinput && sudo udevadm control --reload && sudo udevadm trigger`. Check `ls -l /dev/uinput` shows group `input` and `crw-rw----`.
2. Note the `fn key:` line of `shepetal probe`. Start `ydotoold &` in a terminal and run `shepetal probe` again.
3. Expected: the `fn key:` line is the same as before, and no line names `ydotoold virtual device`.
4. With the laptop keyboard only (fn not visible, L-KEY-2), run `shepetal daemon` while ydotoold runs. Expected: it still exits with the "fn is not visible to Linux" message and does not start.
(Automated: `daemon_waits_for_fn_only_on_keyboards_that_can_send_it`, which includes a fake ydotoold device that declares every key.)

### L-SETUP-5: the 🤫 indicator
1. `sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gtklayershell-0.1 fonts-noto-color-emoji`
2. In the clone's `linux` folder: `mkdir -p ~/.local/bin && ln -s "$PWD/indicator/shepetal-indicator" ~/.local/bin/`. If `~/.local/bin` is new, log out and back in so it is on PATH. Check that `command -v shepetal-indicator` prints it.
3. For GNOME Wayland only, in the same folder: `cp -r gnome-extension ~/.local/share/gnome-shell/extensions/shepetal-indicator@backant.io`, log out and back in, then `gnome-extensions enable shepetal-indicator@backant.io`.
4. `shepetal daemon`. Expected: a small 🤫 in the bottom-left corner of the screen. On GNOME Wayland the daemon also prints `shepetal: on GNOME Wayland 🤫 comes from the shepetal GNOME Shell extension (linux/gnome-extension/)`.
(Automated: `socket_is_owner_only_in_a_private_runtime_dir`, `the_indicator_is_started_again_when_it_exits`, `an_indicator_that_keeps_crashing_backs_off_and_one_that_ran_long_restarts_soon`.)

### L-KEY-1: fn visible on an Apple keyboard
1. Connect an Apple keyboard (Magic Keyboard, USB or Bluetooth) and run `shepetal probe`.
2. Expected: `fn key:    visible on /dev/input/eventN (<the keyboard's name, e.g. Apple Inc. Magic Keyboard>)`. Write down `cat /sys/module/hid_apple/parameters/fnmode` next to the result.
3. `shepetal daemon`. Expected: `shepetal: hold fn to talk, double-tap for hands-free. keyboards /dev/input/eventN (<same name>), …`. Only devices that can send fn are listed.
(Automated: `fn_is_bit_464_of_the_sysfs_key_bitmap`, `last_word_holds_bit_0`, `leading_zero_words_are_dropped`, `default_hotkey_is_fn`, `decodes_fn_press_and_skips_sync`, `daemon_waits_for_fn_only_on_keyboards_that_can_send_it`.)

### L-KEY-2: fn not visible on a laptop keyboard
1. Disconnect every Apple keyboard. On a laptop whose fn is handled in firmware (most are), run `shepetal probe`.
2. Expected: `fn key:    not visible to Linux (many laptops handle fn in firmware); set SHEPETAL_KEY, e.g. rightalt`.
3. `shepetal daemon; echo $?`. Expected: it exits at once with `shepetal: fn is not visible to Linux on this keyboard: no /dev/input/event* device reports KEY_FN (464).`, the lines that say to pick another key with `SHEPETAL_KEY=rightalt shepetal daemon`, and `1`. Pressing fn does nothing; no other key was picked silently.
4. If probe says fn is visible on a laptop keyboard instead, write down the laptop model and run the L-FN steps with its fn.
(Automated: `daemon_waits_for_fn_only_on_keyboards_that_can_send_it`.)

### L-KEY-3: SHEPETAL_KEY
1. `SHEPETAL_KEY=rightalt shepetal daemon`. Expected: `hold rightalt to talk`, and the keyboards that have Right Alt. Hold Right Alt in a text editor and speak: the text is typed (as L-FN-1). With an Apple keyboard connected, fn now does nothing.
2. `SHEPETAL_KEY=58 shepetal daemon` (Caps Lock by evdev code), then tap Caps Lock once. Expected: the hint reads `Hold key 58 to talk · double-tap for hands-free`.
3. `SHEPETAL_KEY=banana shepetal daemon`. Expected: `shepetal: unknown SHEPETAL_KEY "banana"` and exit code 1.
4. `SHEPETAL_KEY` also takes `rightmeta`, `capslock`, `f13` and `rightctrl`. Try one that your keyboard has: it works as in step 1.
(Automated: `daemon_waits_for_fn_only_on_keyboards_that_can_send_it`, `a_numeric_key_is_named_key_n_in_the_hint`.)

In the L-FN steps "fn" is the hotkey: fn on an Apple keyboard, else the key from L-KEY-3. Open the GNOME Text Editor (or Kate on KDE) and click into a new document before each step. Each run of the speech model loads the model again, so the text can take a few seconds after release on a CPU; note the time for #46.

### L-FN-1: hold to talk
1. Hold fn, say "Testing one two three, this is a hold to talk check.", then release.
2. Expected: the sentence is typed at the cursor, starting with "Testing" (recording starts on the press, so the first word is not cut off). The daemon prints no hint.
3. Hold fn for about 5 s without pressing anything else, then release. Expected: one dictation, not several (key repeat is ignored).
4. Tap fn briefly, wait about 1 s, then hold fn and speak. Expected: the first tap prints the hint (L-FN-3), and the hold is typed as in step 2.
(Automated: `hold_of_500ms_is_push_to_talk`, `release_at_499ms_is_a_tap_not_a_stop`, `second_press_after_window_starts_fresh`, `evdev_key_events_reach_the_shortcut_layer_as_is`, `hotkey_gestures_still_work_through_the_shortcut_layer`, `a_key_event_is_stamped_when_it_arrives`, `dictation_keeps_the_audio_the_model_heard`.)

### L-FN-2: double-tap for hands-free
1. Tap fn twice quickly (the second press within half a second of releasing the first) and release.
2. Speak for about 20 s without holding anything. Meanwhile type a few words into the document. Expected: the typing does not stop the recording.
3. Click back to where the text should go and press fn once.
4. Expected: the whole spoken passage is typed there. The daemon prints no hint.
(Automated: `double_tap_gap_is_500ms`, `double_tap_inside_window_is_hands_free_until_next_press`.)

### L-FN-3: too-short press and its hint
1. Tap fn once, briefly (under half a second), and don't tap again.
2. Expected: nothing is typed. About half a second after the release the daemon prints `shepetal: hint: Hold fn to talk · double-tap for hands-free` (with the L-KEY-3 key's name in place of fn), and the same text shows next to 🤫 for about 3 s, then goes. A new `<unix-ms>.tooshort.wav` is in `~/.local/share/shepetal/audio/`.
3. Tap fn and type a word right after it. Expected: the same hint, nothing transcribed.
4. Tap fn and then hold a letter key down so it repeats. Expected: the hint still comes about half a second after the tap, not when you let go of the letter.
(Automated: `single_tap_is_too_short_once_window_expires`, `typing_after_a_tap_is_still_too_short`, `a_tap_ends_as_too_short_on_time_while_a_key_repeats`, `too_short_press_keeps_the_clip_and_shows_the_hint`.)

### L-FN-4: chords and Esc
1. Hold fn and press F1 (on an Apple keyboard, fn+F1 is F1 or brightness down, depending on `fnmode`). Expected: nothing is typed, no hint is printed, and a new `<unix-ms>.cancelled.wav` is in the audio folder.
2. In a long document hold fn and press Left or Down arrow. Expected: the arrow does its fn action (Home or Page Down) or moves the cursor, nothing is typed, no hint, one more `.cancelled.wav`.
3. Hold fn, say a few words, and press Esc while still holding. Expected: the same as step 1: Esc while the hotkey is down is a chord and cancels.
4. Hold fn for about 2 s while speaking, then press Down arrow. Expected: also cancelled, nothing is typed. (Linux cancels at any point of the hold; the Mac only in the first second. Known gap in docs/linux.md.)
5. Double-tap fn for hands-free, speak, and press Esc. Expected: nothing is typed, and a new `<unix-ms>.cancelled.wav` is in the audio folder (L-SC-1).
6. With both an Apple keyboard and the laptop keyboard: hold fn on the Apple keyboard and press a key on the laptop keyboard. Expected: no cancel, the hold is typed on release (only keyboards that can send the hotkey are read; known gap).
(Automated: `chord_with_another_key_cancels`, `cancel_keeps_the_recording`, `esc_cancels_a_hold_a_double_tap_and_a_toggle`.)

In the L-SC steps the shortcuts have their defaults: Esc cancels, Shift+Alt+Z is paste-last, Shift+Alt+X is copy-last and Ctrl+Meta+Space (Ctrl+Super+Space) is the hands-free key. No `~/.config/shepetal/config.json` exists until L-SC-5. shepetal reads the keys without grabbing them, so the focused app gets them too.

### L-SC-1: Esc cancels a dictation
1. Double-tap fn, say a sentence, wait 2 s, and press Esc. Expected: nothing is typed, 🤫 goes back to idle, and `ls ~/.local/share/shepetal/audio` shows a new `<unix-ms>.cancelled.wav`. `pw-play` it: you hear the sentence. The editor also gets the Esc.
2. Press Ctrl+Meta+Space, speak, and press Esc. Expected: the same, with one more `.cancelled.wav`.
3. Hold fn, speak, press Esc while still holding, then release fn. Expected: cancelled as in step 1, and the release starts nothing.
(Automated: `esc_cancels_a_hold_a_double_tap_and_a_toggle`, `esc_in_the_daemon_cancels_and_keeps_the_audio`.)

### L-SC-2: Esc with nothing recording
1. With the daemon idle, open a dialog that closes on Esc (for example Open, Ctrl+O, in the Text Editor) and press Esc. Expected: the dialog closes, and the daemon's terminal shows nothing.
2. Hold fn and dictate a sentence. Expected: it is typed as in L-FN-1.
(Automated: `esc_with_nothing_recording_does_nothing`.)

### L-SC-3: paste-last and copy-last
1. Start the daemon and press Shift+Alt+Z before you dictate anything. Expected: nothing is typed, and next to 🤫 shows `Nothing dictated yet` (stderr: `shepetal: hint: Nothing dictated yet`). Shift+Alt+X gives the same.
2. Dictate a sentence. Click into another text field and press Shift+Alt+Z. Expected: the same sentence is typed once you let go of all three keys.
3. Press Shift+Alt+X, then Ctrl+V in a third field. Expected: the same sentence is pasted.
4. Restart the daemon and press Shift+Alt+Z. Expected: `Nothing dictated yet` again. The last text lives only in the running daemon until history lands (#67).
5. Write down whether the focused app also reacted to Shift+Alt+Z or Shift+Alt+X.
(Automated: `paste_and_copy_last_fire_once_every_key_is_up`, `a_combo_needs_exactly_its_keys`, `defaults_are_wisprs_windows_keys`, `paste_last_and_copy_last_keys_repeat_the_last_dictation`.)

### L-SC-4: the hands-free key
1. Press Ctrl+Meta+Space, let go, and speak for about 10 s while typing a few words in the document. Expected: the orange ring from the press on, and the typing does not stop the recording. Press Ctrl+Meta+Space again. Expected: the spoken text is typed.
2. Press Ctrl+Meta+Space twice quickly (the second press within half a second of the first). Expected: nothing is typed, and a new `.cancelled.wav` is in the audio folder.
3. Press Ctrl+Meta+Space, speak, then press fn once. Expected: the text is typed, and no second recording starts (🤫 alone afterwards).
4. Double-tap fn, speak, then press Ctrl+Meta+Space. Expected: the text is typed. Hold fn and speak: a new dictation, typed on release.
5. Write down whether GNOME or KDE also reacted to Ctrl+Super+Space.
(Automated: `hands_free_toggle_starts_stops_and_cancels`, `hands_free_is_reported_for_the_toggle_and_the_double_tap`, `the_hotkey_stops_a_toggled_dictation_without_starting_another`, `the_toggle_ends_a_double_tap_dictation`.)

### L-SC-5: shortcut settings
1. Put `{"shortcuts": {"paste_last": "z"}}` in `~/.config/shepetal/config.json` and run `shepetal daemon; echo $?`. Expected: `shepetal: /home/<you>/.config/shepetal/config.json: paste_last: "z" needs a modifier: ctrl, alt, shift, meta or a mouse button` and `1`.
2. With `{"shortcuts": {"paste_last": "ctrl+alt+shift+z"}}`. Expected: `... paste_last: "ctrl+alt+shift+z" has 4 keys, at most 3 are allowed` and `1`.
3. With `{"shortcuts": {"hands_free": "shift+alt+z"}}`. Expected: `... hands_free: "shift+alt+z" is already paste_last` and `1`.
4. With `{"shortcuts": {"paste_last": "ctrl+alt+v"}}` the daemon starts. Dictate a sentence and press Ctrl+Alt+V. Expected: the sentence is typed again, Shift+Alt+Z does nothing, and Shift+Alt+X still copies (a shortcut left out keeps its default).
5. With `{"shortcuts": {"copy_last": "rightalt+x"}}`, run `SHEPETAL_KEY=rightalt shepetal daemon`. Expected: `... copy_last: "rightalt+x" uses rightalt, the dictation hotkey` and exit code 1. Remove the file and run `SHEPETAL_KEY=rightalt shepetal daemon` again. Dictate with Right Alt, then press Shift+Left Alt+Z. Expected: the sentence is typed again (a generic `alt` means Left Alt when Right Alt is the hotkey).
6. Remove `~/.config/shepetal/config.json`.
(Automated: `validation_rejects_what_wispr_rejects`, `combos_that_clash_with_the_hotkey_are_rejected`, `config_errors_name_the_shortcut_and_place`, `config_overrides_and_other_settings_are_skipped`, `config_file_location_and_missing_file`, `key_names_map_to_evdev_codes`.)

### L-SC-7: a combo as the dictation key
1. Put `{"shortcuts": {"dictation": "ctrl+alt"}}` in `~/.config/shepetal/config.json` and run `shepetal daemon` without `SHEPETAL_KEY`. Expected: `hold ctrl+alt to talk`, and the keyboards that have Ctrl or Alt.
2. In a text editor hold Ctrl, then Alt, and speak; let go. Expected: the text is typed once the keys are up. Do it again pressing Right Alt first, then Right Ctrl: the same.
3. Hold Ctrl+Alt, let go of Alt and press it again within half a second while Ctrl stays down, then let go of both. Expected: hands-free (🤫 orange). Press Ctrl+Alt again: the text is typed.
4. Tap Ctrl+Alt quickly. Expected: nothing is typed and `Hold ctrl+alt to talk · double-tap for hands-free` shows next to 🤫 for about 3 s.
5. Press Ctrl+Alt+T (or any Ctrl+Alt+key your desktop uses). Expected: the desktop's action happens and nothing is typed (a chord, kept as `*.cancelled.wav`).
6. Hold only Ctrl for 2 s. Expected: no recording.
7. Each of these, one at a time, makes `shepetal daemon; echo $?` exit with `1` and the reason after `config.json: dictation:`: `"a"` (`needs a modifier`), `"7"` (the same), `"shift+a"` (`types a character`), `"ctrl+alt+shift+meta"` (`has 4 keys, at most 3 are allowed`), `"leftctrl"` (`a key you press all the time`), `"alt+tab"` (`a shortcut the desktop or apps already use`), `"mouse1"` (`left and right click cannot be shortcuts`).
8. With `{"shortcuts": {"dictation": "ctrl+alt"}}` still in the file, run `SHEPETAL_KEY=rightctrl shepetal daemon`. Expected: `hold rightctrl to talk`: `SHEPETAL_KEY` wins over the file.
9. Remove `~/.config/shepetal/config.json`.
(Automated: `a_combo_is_a_dictation_key_held_in_any_order`, `dictation_validation_matches_the_mac`, `other_shortcuts_may_not_overlap_a_combo_dictation_key`, `shepetal_key_still_picks_one_key_and_wins_over_the_config`, `a_combo_or_mouse_dictation_key_reads_every_device_that_sends_part_of_it`.)

### L-SC-8: mouse buttons
Needs a mouse with back and forward side buttons.
1. `sudo evtest`, pick the mouse, and press its back and forward buttons. Write down the names it prints (`BTN_SIDE`/`BTN_EXTRA`, or `BTN_BACK`/`BTN_FORWARD`). Quit evtest.
2. Put `{"shortcuts": {"dictation": "mouse4", "hands_free": "mouse5"}}` in `~/.config/shepetal/config.json` and run `shepetal daemon`. Expected: `hold mouse4 to talk`, and the mouse among the input devices.
3. Hold the back button and speak in a text editor; while still holding it, left-click in the editor once. Let go. Expected: the text is typed (the click did not cancel), and the browser or file manager under the pointer may also go back, since nothing is swallowed.
4. Double-click the back button, speak, press it again. Expected: hands-free, then the text is typed.
5. Press the forward button, speak, press it again. Expected: the text is typed (the hands-free key). Pressed twice within half a second: nothing is typed and a `*.cancelled.wav` is kept.
6. Set `{"shortcuts": {"dictation": "ctrl+mouse4"}}`: holding Ctrl and the back button records; the back button alone does nothing.
7. Unplug the mouse and start the daemon with step 6's file. Expected: `no input device reports "ctrl+mouse4" (evdev code 275)` and exit code 1. Remove `~/.config/shepetal/config.json`.
(Automated: `a_mouse_button_is_a_dictation_key_and_clicks_do_not_cancel_it`, `a_combo_or_mouse_dictation_key_reads_every_device_that_sends_part_of_it`.)

### L-SC-6: 20-minute cap
1. Start a hands-free dictation (double-tap fn or Ctrl+Meta+Space) and leave it running for 20 min, speaking now and then.
2. Expected: at 19 min next to 🤫 shows `Recording stops in 1 minute` (stderr: `shepetal: hint: Recording stops in 1 minute`), and a desktop notification says the same. At 20 min the recording stops by itself and the text is typed. Write down how long the text took after the stop: the whole clip goes to the model at once.
(Automated: `warning_at_19_minutes_and_stop_at_20`, `a_20_minute_hold_stops_and_the_late_release_does_nothing`.)

### L-LEN-1: a configurable cap (F10)
1. `sudo apt install libnotify-bin` (for `notify-send`). Put `{"dictation": {"max_minutes": 2}}` in `~/.config/shepetal/config.json` and start `shepetal daemon`, with a text editor focused.
2. Double-tap fn and keep talking. Expected: after 1 minute `Recording stops in 1 minute` shows next to 🤫 and as a desktop notification (on GNOME Wayland without the extension, only the notification). After 2 minutes the recording stops by itself and everything said is typed, as if you had tapped fn. No sound plays.
3. Hold fn (no double-tap) and keep talking for over 2 minutes. Expected: the same warning at 1 minute; at 2 minutes the text is typed while fn is still down, and letting go of fn afterwards starts nothing and shows no hint.
4. `ls -t ~/.local/share/shepetal/audio | head -2`. Expected: both recordings are there, not marked cancelled, each about 2 minutes long.
5. Put `{"dictation": {"max_minutes": 0}}` in the file and start the daemon. Expected: it exits with `...config.json: dictation.max_minutes: expected whole minutes from 1 to 1440, got 0`.
6. Remove `dictation` from the file and restart. Expected: the cap is back to 20 minutes (L-SC-6).
(Automated: `the_cap_is_configurable_for_holds_double_taps_and_the_toggle`, `a_one_minute_cap_warns_at_the_start`, `max_minutes_must_be_whole_minutes_from_1_to_a_day`, `a_dictation_that_reaches_the_cap_is_warned_stopped_and_typed`, `warning_at_19_minutes_and_stop_at_20`, `a_20_minute_hold_stops_and_the_late_release_does_nothing`.)

### L-AUD-1: every recording is kept, owner-only
1. After L-FN-1 to L-FN-4, run `stat -c '%a %U %n' ~/.local/share/shepetal/audio ~/.local/share/shepetal/audio/*`.
2. Expected: the folder is `700` and each file is `600`, all owned by you. There is one file per press: `<unix-ms>.wav` for each dictation, `<unix-ms>.tooshort.wav` for each tap, `<unix-ms>.cancelled.wav` for each chord. Nothing was deleted.
3. `file ~/.local/share/shepetal/audio/*.wav`. Expected: every one is `RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 16000 Hz`.
4. `pw-play` the newest `<unix-ms>.wav` (no label). Expected: you hear the whole sentence of that dictation, first word included. It is the file the model read. Play a `.cancelled.wav`: you hear what you said until the chord.
5. `ls -la /tmp | grep -i -e shepetal -e '\.wav'`. Expected: nothing from shepetal.
(Automated: `recording_is_private_and_always_kept`, `dictation_keeps_the_audio_the_model_heard`, `cancel_keeps_the_recording`, `too_short_press_keeps_the_clip_and_shows_the_hint`.)

### L-AUD-2: an unsafe audio folder is refused
1. With the daemon running, `chmod 755 ~/.local/share/shepetal/audio` and press fn.
2. Expected: the daemon exits with `shepetal: audio file: /home/<you>/.local/share/shepetal/audio must be a 0700 directory`. Nothing is recorded or typed.
3. `chmod 700 ~/.local/share/shepetal/audio`. Then `mv ~/.local/share/shepetal/audio ~/audio-kept && mkdir -m 700 /tmp/swap && ln -s /tmp/swap ~/.local/share/shepetal/audio`, start the daemon, and press fn. Expected: the same refusal, and `/tmp/swap` stays empty.
4. Undo: `rm ~/.local/share/shepetal/audio && rmdir /tmp/swap && mv ~/audio-kept ~/.local/share/shepetal/audio`.
(Automated: `an_audio_dir_open_to_others_is_refused`.)

### L-AUD-3: XDG_DATA_HOME
1. `cd /tmp && XDG_DATA_HOME=relative shepetal daemon`, hold fn and speak. Expected: the clip lands in `~/.local/share/shepetal/audio/`, and no `/tmp/relative` exists.
2. `XDG_DATA_HOME=$HOME/xdg-test SHEPETAL_MODEL=$HOME/.local/share/shepetal/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8 shepetal daemon`, hold fn and speak. Expected: the clip lands in `~/xdg-test/shepetal/audio/`, folder `700`, file `600`. Remove `~/xdg-test` afterwards.
(Automated: `audio_never_goes_under_a_relative_or_empty_xdg_data_home`.)

### L-AUD-4: the keyboard goes away mid-recording
1. With fn visible only on an Apple keyboard, start the daemon, double-tap fn and speak. Unplug the keyboard (or switch a Bluetooth one off).
2. Expected: the daemon exits with `shepetal: all input devices closed`, a new `.cancelled.wav` is in the audio folder, and `pgrep -a pw-record` prints nothing (the mic is released).
(Automated: `losing_every_keyboard_mid_recording_stops_the_recorder`.)

In the L-MIC steps a USB mic is plugged in (any external mic works). `command -v notify-send` must print a path (package `libnotify-bin`): the mic alerts are desktop notifications, and 🤫 shows a few words of each.

### L-MIC-1: the ranked mic list
1. With no `[mic]` section in `~/.config/shepetal/config.toml`, run `shepetal mics`. Expected: one line per mic, without monitors or echo-cancel sources. The first is marked `*` and `(desktop default)` and is the one `pactl get-default-source` names. The built-in mic is marked `(built-in)` and comes after the external mics unless it is the default. The last line names the config file.
2. Put these two lines in `~/.config/shepetal/config.toml`: `[mic]` and `prefer = ["<part of the USB mic's name>"]`. Run `shepetal mics`. Expected: the USB mic is first, with `*` and `(preference #1 "<that text>")`.
3. Start the daemon, double-tap fn and speak. In another terminal run `pgrep -a pw-record`. Expected: `--target <the USB mic's node name>`, the name `shepetal mics` prints after `[usb]` (`--device=` with parecord). Press fn: the text is typed. `pw-play` the newest clip: it is the USB mic's sound.
(Automated: `pw_dump_lists_hardware_sources_only`, `pactl_json_skips_monitors`, `ranking_follows_the_users_list_then_default_external_builtin`, `config_reads_only_mic_prefer`, `records_from_the_picked_mic`, `mics_command_lists_in_rank_order`, `dictation_keeps_the_audio_the_model_heard`.)

### L-MIC-2: a mic plugged in or out between dictations
1. Keep the L-MIC-1 preference. Unplug the USB mic and run `shepetal mics`. Expected: the next mic is first with `*`.
2. Dictate. Expected: on the press, next to 🤫 shows `Mic: <that mic's name> (the last one is gone)` (also on stderr), and the text is typed.
3. Plug the USB mic back in and dictate. Expected: `Mic: <the USB mic's name> (ranked higher)`, and the clip is from the USB mic.
4. Dictate once more. Expected: no `Mic:` hint.
(Automated: `hot_plug_switches_at_the_next_record_start`.)

### L-MIC-3: the mic unplugged mid-dictation
1. Double-tap fn, say a sentence into the USB mic, and unplug it while still in hands-free.
2. Expected: within about 2 s a notification `Mic disconnected: <mic>. Dictation stopped; what you said before is kept.`, `Mic disconnected` next to 🤫, and the sentence is typed without another press. `pgrep -a pw-record` prints nothing.
3. Hold fn and speak. Expected: a new dictation on the next mic, typed on release (the press does not just end the old one).
4. Press Shift+Alt+Z. Expected: the sentence from step 1 is typed again.
(Automated: `unplugging_the_mic_mid_dictation_stops_with_an_alert`, `a_mic_unplugged_mid_dictation_ends_it_and_types_what_was_said`, `after_a_reset_the_next_press_starts_a_new_dictation`, `the_indicator_gets_a_few_words_and_no_device_name`.)

### L-MIC-4: a silent mic
1. Mute the mic marked `*` in `shepetal mics`: `pactl set-source-mute <its node name> 1`, or its hardware mute switch.
2. Double-tap fn, wait about 7 s, then press fn. Expected: after about 5 s one notification `No sound from <mic>: it sends only silence. Check that it is not muted, or rank another one (shepetal mics).`, and `No sound from the mic` next to 🤫.
3. Within a minute, do step 2 again. Expected: no second notification.
4. `pactl set-source-mute <its node name> 0` and dictate in a whisper. Expected: no notification.
(Automated: `no_audio_only_after_more_than_5_s_of_exact_zeros`, `real_audio_resets_the_silence_count`, `health_reads_a_growing_wav_and_catches_a_dead_mic`, `wav_samples_start_after_the_data_chunk`, `alerts_are_rate_limited_per_kind`.)

### L-MIC-5: lid closed
1. On a laptop with an external display, keyboard and mic, put part of the built-in mic's name first in `prefer`, then close the lid. `cat /proc/acpi/button/lid/*/state`. Expected: `state: closed`. If there is no such file, write down the laptop model: the lid is then not seen (known gap in docs/linux-mic.md).
2. `shepetal mics`. Expected: the built-in mic is last, marked `built-in, lid closed: last resort`, though it is preferred.
3. Dictate. Expected: the clip is from the first mic in the list, not the built-in one.
(Automated: `lid_closed_puts_the_builtin_mic_last_even_when_preferred`, `lid_state_from_acpi`.)

### L-MIC-6: no sound server
1. With the daemon running, `systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber` (stop the sockets too, or the next `pw-dump` starts PipeWire again).
2. `shepetal mics; echo $?`. Expected: `shepetal: No PipeWire or PulseAudio found, so shepetal cannot record. Install pipewire-bin (or pulseaudio-utils) and start the sound server.` and `1`.
3. Press fn. Expected: a notification with the same text, and `No PipeWire or PulseAudio` next to 🤫. Write down what else the daemon prints.
4. `systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber` and dictate. Expected: it works again.
(Automated: `alerts_are_rate_limited_per_kind`, `the_indicator_gets_a_few_words_and_no_device_name`.)

### L-MIC-7: a mic that stops sending
1. Run the daemon with a USB mic marked `*` in `shepetal mics`. Double-tap fn and say a sentence.
2. In another terminal freeze the recorder's input: `pactl suspend-source <the USB mic's node name> 1` (a suspended source delivers nothing). If your PipeWire keeps it running, stop the recorder's data instead with `kill -STOP $(pgrep pw-record)`, then `kill -CONT` it after 7 s.
3. Expected: about 5 s later a notification `Cannot read <mic>: no sound arrived for 5 s. Dictation stopped; what you said before is kept. ...`, `Cannot read the mic` next to 🤫 (yellow), and the sentence is typed without another press. `pgrep -a pw-record` prints nothing. No sound plays.
4. `pactl suspend-source <name> 0`. Hold fn and speak. Expected: a new dictation, typed on release.
(Automated: `no_samples_for_5_s_stops_with_mic_unreadable`, `a_mic_that_stops_sending_ends_the_dictation_and_types_what_was_said`, `advice_is_a_hint_and_problems_are_errors`.)

### L-MIC-8: a Bluetooth headset mic
Needs a Bluetooth headset with a mic (AirPods, a Jabra) and the laptop's built-in mic.
1. Connect the headset and put part of its name first in `prefer` in `~/.config/shepetal/config.toml`. `shepetal mics`: the headset is first, `[bluetooth]`.
2. Start the daemon, play some music through the headset, and dictate. Expected: on the press, a notification `<headset> is a Bluetooth headset: while it records, it switches to its low-quality call mode ...`, and `Bluetooth mic: lower quality` next to 🤫 in the hint style (🤫 does not turn yellow). The music sounds worse while recording: that is the headset's call profile. The text is typed. No sound is added by shepetal.
3. Dictate again. Expected: no second notification while the daemon runs.
4. Restart the daemon, disable the built-in mic (`pactl set-card-profile <the laptop card> off`) so the headset is the only mic, and dictate. Expected: no Bluetooth notification: there is nothing better to switch to. Turn the card profile back on.
(Automated: `a_bluetooth_headset_mic_is_advised_once`, `advice_is_a_hint_and_problems_are_errors`.)

### L-MIC-9: lid closed on the only mic
1. On a laptop with an external display and keyboard but no external mic, close the lid (`cat /proc/acpi/button/lid/*/state` says `closed`).
2. Start the daemon and dictate. Expected: a notification `The lid is closed and the built-in mic is the only one, so it may sound muffled. Open the lid or plug in a mic.` and `Lid closed: mic muffled` next to 🤫 in the hint style. The text is typed.
3. Dictate again. Expected: no second notification while the daemon runs. With an external mic plugged in (restart the daemon): no notification.
(Automated: `the_lid_closed_on_the_only_mic_is_advised_once`, `lid_state_from_acpi`.)

The dictionary and snippets live in `~/.config/shepetal/` and are read again at every dictation, so the daemon keeps running through the L-VOC steps.

### L-VOC-1: dictionary words and replacements
1. `shepetal dict add GitHub`, `shepetal dict add 'thanks => thank you very much'` and `shepetal dict add 'cat => dog'`, then `shepetal dict list`. Expected: the three entries. `stat -c '%a %n' ~/.config/shepetal ~/.config/shepetal/dictionary.txt`: `700` and `600`.
2. Hold fn and say "Thanks, I pushed it to github." Expected: `Thank you very much, I pushed it to GitHub.` The capital at "Thanks" is kept.
3. Say "Okay, thanks." Expected: `Okay, thank you very much.`
4. Say "The category has two cats." Expected: typed unchanged: `cat` only matches the whole word.
5. `shepetal dict remove thanks` and do step 3 again. Expected: `Okay, thanks.`
(Automated: `dictionary_fixes_casing_whole_words_only`, `replacement_keeps_a_sentence_capital`, `longest_first_and_never_replaced_again`, `unicode_words_and_boundaries`, `dictionary_lines`, `config_dir_follows_xdg`, `cli_edits_owner_only_files`, `the_dictionary_biases_whisper_and_fixes_the_text`.)

### L-VOC-2: the model hint
1. On a machine where `shepetal probe` names the Whisper model (Vulkan, docs/linux.md step 2), say "Shepetal types what I say." Write down how the name is spelled.
2. `shepetal dict add '*Shepetal'` and say the sentence again. Expected: `Shepetal types what I say.`
3. On a Parakeet machine, do steps 1 and 2 and write down the spelling. Parakeet gets no hint, so only the casing of an exact match is fixed (F39).
(Automated: `prompt_puts_starred_last_and_is_capped`, `the_dictionary_biases_whisper_and_fixes_the_text`.)

### L-VOC-3: snippets
1. `shepetal snippet add 'my address' '221B Baker Street, London'`, then `shepetal snippet list`. Expected: `my address => 221B Baker Street, London`. `stat -c '%a' ~/.config/shepetal/snippets.toml`: `600`.
2. Hold fn and say only "My address." Expected: `221B Baker Street, London` is typed alone, exactly as written.
3. Say "Please send it to my address today." Expected: `Please send it to 221B Baker Street, London today.`
4. `shepetal snippet remove 'my address'` and do step 2 again. Expected: `My address.`
(Automated: `whole_dictation_snippet_ignores_case_and_punctuation`, `inline_snippet_expands_inside_a_sentence`, `longest_first_and_never_replaced_again`, `snippets_toml_round_trips`, `cli_edits_owner_only_files`, `the_dictionary_biases_whisper_and_fixes_the_text`.)

### L-INS-1: ydotool on GNOME Wayland
1. In the "Ubuntu" session, with `ydotoold` running (L-SETUP-4), start `shepetal daemon`. Expected: its first line ends with `insert Ydotool`.
2. In the GNOME Text Editor hold fn and say "Send the report today, then call Anna."
3. Expected: the sentence is typed at the cursor, with the comma and the period. Repeat in GNOME Terminal and in a Firefox text field: the same.
4. ydotool sends keycodes, so the result depends on the layout. With a non-US layout (for example German), write down any swapped letters (y/z) or wrong punctuation.
5. Stop ydotoold and dictate again. Write down what happens: ydotool 0.1.8 may still type without the daemon (it prints `ydotoold backend unavailable`), or the daemon prints `shepetal: insert: ydotool failed: …` and nothing is typed. After a failure nothing is typed, and the text is on the clipboard with `Typing failed. The text is on the clipboard: press Ctrl+V (Ctrl+Shift+V in a terminal).` next to 🤫. The clip is still kept.
(Automated: `gnome_wayland_skips_wtype`, `text_goes_over_stdin_not_argv`.)

### L-INS-2: wtype on KDE Wayland
1. In "Plasma (Wayland)", start `shepetal daemon`. Expected: `insert Wtype`.
2. In Kate hold fn and say "Send the report today, then call Anna."
3. Expected: the sentence is typed at the cursor. If nothing is typed and the daemon prints `shepetal: insert: wtype failed: …` (the text is then on the clipboard with the `Typing failed.` hint; for example "Compositor does not support the virtual keyboard protocol"), write it down with `plasmashell --version`: KWin may refuse wtype, and v0 does not fall back to ydotool after a failure.
(Automated: `session_type_picks_native_typer`, `text_goes_over_stdin_not_argv`.)

### L-INS-3: xdotool on X11
1. In "Ubuntu on Xorg", start `shepetal daemon`. Expected: `insert Xdotool`.
2. In the GNOME Text Editor, in GNOME Terminal and in a Firefox text field, hold fn and say "Send the report today, then call Anna."
3. Expected: the sentence is typed in each, with no stuck Shift or Ctrl afterwards (`--clearmodifiers`). Say "café" once: write down whether the é is typed.
(Automated: `session_type_picks_native_typer`, `text_goes_over_stdin_not_argv`.)

### L-INS-4: ydotool as the fallback on X11 and KDE
1. On X11: `sudo apt remove xdotool`, start `ydotoold &` (L-SETUP-4) and run `shepetal probe`. Expected: `insert:    Some(Ydotool)`. Dictate as in L-INS-3: the sentence is typed.
2. On KDE: `sudo apt remove wtype` and do the same. Expected: `Some(Ydotool)`, and the sentence is typed.
3. `sudo apt install xdotool wtype` again.
(Automated: `ydotool_then_clipboard_are_fallbacks`.)

### L-INS-5: clipboard fallback
1. On GNOME Wayland: `sudo apt remove wtype ydotool`. `shepetal probe`. Expected: `insert:    Some(WlCopy)`.
2. Copy a word, say "earlier", with Ctrl+C. Start the daemon, hold fn in the Text Editor, say a sentence, release.
3. Expected: nothing is typed, and next to 🤫 shows `No typing tool. The text is on the clipboard: press Ctrl+V (Ctrl+Shift+V in a terminal).` Ctrl+V pastes the sentence, not "earlier" (the old clipboard is not restored, docs/linux.md).
4. On X11: `sudo apt remove xdotool ydotool`. Expected: `Some(Xclip)`, and steps 2 and 3 give the same result.
5. Remove `wl-clipboard` and `xclip` too and start the daemon. Expected: it exits with `shepetal: no text insertion tool: install wtype, xdotool, ydotool, wl-clipboard or xclip`.
6. `sudo apt install wtype xdotool ydotool wl-clipboard xclip` again.
(Automated: `ydotool_then_clipboard_are_fallbacks`, `text_goes_over_stdin_not_argv`, `unreadable_focus_types_and_failed_typing_falls_back_to_the_clipboard`.)

### L-FOC-1: text only goes into the window that kept focus (X11, Sway, Hyprland)
1. In "Ubuntu on Xorg", start `shepetal daemon`. Open the GNOME Text Editor and GNOME Terminal. Copy a word, say "earlier", with Ctrl+C.
2. In the Text Editor, double-tap fn, say "Send the report today.", click into the terminal, and press fn once. Expected: nothing is typed in either window, focus stays on the terminal, and next to 🤫 shows `Focus moved. The text is on the clipboard: press Ctrl+V (Ctrl+Shift+V in a terminal).` Ctrl+Shift+V pastes the sentence into the terminal.
3. Copy "earlier" again and repeat step 2 without leaving the Text Editor. Expected: the sentence is typed there, and Ctrl+V in another field still pastes "earlier".
4. If you have Sway (`sudo apt install sway`, then "Sway" at login) or Hyprland, repeat steps 2 and 3 there with its terminal. Expected: the same.
(Automated: `only_the_same_window_gets_the_text`, `session_picks_how_focus_is_read`, `text_is_typed_only_into_the_window_that_kept_focus`, `text_goes_to_the_clipboard_when_focus_moved`, `focus_is_read_again_when_the_text_is_ready`, `focus_is_read_from_sway_and_hyprland`, `sway_tree_gives_the_focused_node`, `hyprland_gives_the_active_window_address`, `a_hung_focus_tool_is_cut_off`.)

### L-FOC-2: GNOME and KDE on Wayland
1. In "Ubuntu", start `shepetal daemon`. Expected: it also prints `shepetal: this desktop does not tell apps which window has focus, so text is typed into whatever window has focus when it is ready (goal rule 8 needs X11, Sway or Hyprland)`.
2. Do L-FOC-1 step 2. Expected: the sentence is typed into the terminal, the window with focus at the end, and no hint shows.
3. In "Plasma (Wayland)", do steps 1 and 2. Expected: the same.
(Automated: `session_picks_how_focus_is_read`, `unreadable_focus_types_and_failed_typing_falls_back_to_the_clipboard`.)

### L-IND-1: 🤫 on X11
1. In "Ubuntu on Xorg" (or Xfce or i3), run `shepetal daemon`. Expected: a small 🤫 about 8 px in from the bottom-left corner of the primary monitor (the one `xrandr` marks `primary`), over the panel if one is there.
2. Switch workspaces. Expected: 🤫 stays. Play a video full screen in Firefox. Expected: 🤫 stays on top (a window mapped above it can cover it for up to a second; known gap in docs/linux.md).
3. Click on 🤫. Expected: the click reaches what is below, and the focused window does not change.
4. Hold fn and talk. Expected: red ring. Release: blue pulsing ring, then 🤫 alone once the text is typed. Double-tap fn. Expected: orange ring until the next press.
5. Tap fn once. Expected: `Hold fn to talk · double-tap for hands-free` to the right of 🤫 for about 3 s (goal rule 2).
6. Stop the daemon with Ctrl+C. Expected: 🤫 disappears. Start it again and run `pkill -9 -f 'shepetal daemon'` in another terminal. Expected: 🤫 disappears too.
(Automated: `every_indicator_gets_the_state_and_late_ones_the_current_one`, `the_indicator_shows_each_step_of_a_hands_free_dictation`, `a_too_short_press_shows_the_hint_next_to_the_indicator`, `a_silent_recording_puts_the_indicator_back_to_idle`, `a_failed_dictation_turns_the_indicator_yellow`, `a_reader_that_never_reads_cannot_stall_the_daemon`, `a_running_daemon_keeps_its_socket_and_a_dead_ones_is_replaced`; the X11 screenshots of `linux/indicator/check.sh`.)

### L-IND-2: 🤫 on KDE Plasma Wayland
1. In "Plasma (Wayland)", do L-IND-1. Expected: the same. 🤫 sits over the bottom panel, and a click on it reaches the panel button below it.
2. With two monitors, write down which one 🤫 is on: wlr-layer-shell has no primary output, so it goes to the one GTK reports as primary, else the first (known gap in docs/linux.md).
(Automated: as L-IND-1; the wlr-layer-shell screenshots of `linux/indicator/check.sh` run in headless Sway.)

### L-IND-3: 🤫 on Sway or Hyprland
1. In Sway or Hyprland, do L-IND-1 with a full-screen window open (`fullscreen` in Sway, the `fullscreen` dispatcher in Hyprland). Expected: the same.
(Automated: as L-IND-2.)

### L-IND-4: 🤫 from the GNOME Shell extension
1. In "Ubuntu" with the extension from L-SETUP-5 enabled, start `shepetal daemon`. Expected: it prints that 🤫 comes from the extension, and 🤫 appears within 2 s.
2. Do the checks of L-IND-1 steps 2 to 5, also over a full-screen video and in the Activities overview.
3. Stop the daemon with Ctrl+C. Expected: 🤫 disappears. Start it again. Expected: 🤫 is back within about 2 s.
4. `gnome-extensions disable shepetal-indicator@backant.io`. Expected: 🤫 disappears, and `journalctl --user -b | grep -i shepetal` shows no errors from the extension. Write down `gnome-shell --version`: the extension lists shell versions 45 to 51 without a run on any of them.
(Automated: eslint and the gjs lifecycle run with stand-ins for the Shell modules in `linux/indicator/check.sh`.)

### L-IND-5: two monitors and HiDPI
1. With a second monitor left of the primary, start the daemon. Expected: 🤫 is on the primary.
2. Make the other monitor primary (Settings > Displays). Expected: 🤫 moves there.
3. At 200% scale. Expected: 🤫 is about 36 physical pixels, 16 from the corner.
(Automated: `test_bottom_left_of_a_1080p_monitor`, `test_primary_monitor_right_of_or_below_another` in `linux/indicator/test_indicator.py`, run by `linux/indicator/check.sh`.)

### L-IND-6: 🤫 without the hotkey
1. With no daemon running, on any of the desktops: `printf 'recording\nhint Hello from shepetal\n' | (cat; sleep 5) | shepetal indicator`.
2. Expected: a red ring and `Hello from shepetal` next to 🤫 for about 3 s, then 🤫 disappears when the command ends.
(Automated: `every_indicator_gets_the_state_and_late_ones_the_current_one`.)

### L-IND-7: shepetal-indicator not installed, then installed (#130)
1. On Ubuntu 24.04 in "Ubuntu on Xorg", move the link away: `mv ~/.local/bin/shepetal-indicator ~/.local/bin/shepetal-indicator.off`, then run `shepetal daemon` and leave it running for 2 min.
2. Expected: no 🤫, dictation still works, and stderr has exactly one line `shepetal: 🤫 indicator not started: shepetal-indicator: not installed, or python3 is missing (see docs/linux.md); looking for it again every 64s at most`. No `indicator exited (exit status: 127)` lines, and `top` shows the daemon idle.
3. `mv ~/.local/bin/shepetal-indicator.off ~/.local/bin/shepetal-indicator`. Expected: 🤫 appears within about 64 s without restarting the daemon.
4. `pkill -f shepetal-indicator`. Expected: one `indicator exited (...)` line and 🤫 back after about 2 s.
(Automated: `a_missing_indicator_is_looked_up_on_path_and_never_spawned`, `a_missing_indicator_is_reported_once_and_looked_for_with_backoff`, `an_indicator_that_keeps_crashing_backs_off_and_one_that_ran_long_restarts_soon`, `the_indicator_is_started_again_when_it_exits`.)

### L-MEET-1: a Zoom call in probe
1. Install the Zoom `.deb` from zoom.us and join a call (zoom.us/test, or a call with a second device). Unmute.
2. `shepetal probe`. Expected: a `mic user:` line with `meeting=Some("Zoom")`. Write down the full line (the app and binary names Zoom uses).
3. Mute in Zoom and run `probe` again. Write down whether the line stays (Zoom may keep the stream running).
4. Leave the call and run `probe` again. Expected: no Zoom line.
(Automated: `finds_meeting_apps_on_the_mic`, `ignores_idle_streams_monitors_playback_and_itself`, `garbage_dump_is_empty_not_a_panic`.)

### L-MEET-2: a Google Meet call in a browser
1. In Firefox open meet.google.com, start a new meeting and allow the microphone.
2. `shepetal probe`. Expected: a `mic user:` line with `meeting=Some("Browser (Firefox)")`, and `system audio: Some("<pactl get-default-sink>.monitor")`.
3. Close the tab and run `probe` again. Expected: the line is gone.
4. Repeat in Chrome or Chromium. Expected: `meeting=Some("Browser (Chrome/Chromium)")`.
5. Keep the Zoom call from L-MEET-1 open at the same time as a Meet tab. Expected: both lines are listed.
(Automated: `finds_meeting_apps_on_the_mic`, `system_audio_is_default_sink_monitor`.)

### L-MEET-3: shepetal's own recording is not a meeting
1. Start the daemon, double-tap fn and keep speaking. In another terminal run `shepetal probe`.
2. Expected: no `mic user:` line for shepetal or `pw-record`. If one shows (for example `pw-record (pw-record)`), `pw-record -P '{ application.name = shepetal }'` did not rename the stream: write down the line (docs/linux.md, known gaps).
3. Tap fn to end the dictation.
(Automated: `ignores_idle_streams_monitors_playback_and_itself`.)

In the L-MEET-4 to L-MEET-11 steps `shepetal daemon` records meetings (docs/linux-meetings.md). Before them: `sudo apt install cmake g++ libnotify-bin`, then `git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp && cmake -B build && cmake --build build -j` (on a Vulkan machine build it as in docs/linux.md, "Manual test steps", step 2), `ln -s "$PWD/build/bin/whisper-cli" ~/.local/bin/`, and `./models/download-ggml-model.sh large-v3-turbo-q5_0 && cp models/ggml-large-v3-turbo-q5_0.bin ~/.local/share/shepetal/` (on a Vulkan machine it is already there: it is the dictation model). Check that `command -v whisper-cli` and `command -v notify-send` print a path. Turn Do Not Disturb off, wear headphones (without them the other side is recorded in Me.wav too), and have a second device in the call to play the other side. Remove `~/.config/shepetal/config.json` unless a step says otherwise.

### L-MEET-4: a Zoom call, offered, recorded after Record and transcribed
1. `shepetal daemon`. Expected, after the `hold fn to talk` line: `shepetal: meeting detection on, asking before each recording, Thresholds { poll: 2000, start_after: 5000, min_session: 15000, end_with_evidence: 3000, reacquire: 4000, device_change: 10000, prompt: 20000 } ms (SHEPETAL_MEETING_THRESHOLDS)`, and no `meetings are recorded but not transcribed` line.
2. Join a Zoom call (zoom.us/test, or a call with the second device) and unmute. Expected within about 8 s: a notification "Record this meeting?" with "Zoom is using the microphone. Nothing is recorded unless you click Record." and a Record button, and `shepetal: meeting (Zoom) detected, asking: Record this meeting?` on stderr. `ls ~/.local/share/shepetal/meetings/` shows no new folder, and `pgrep -a pw-record` prints nothing.
3. Click Record. Expected within about 2 s: `shepetal: meeting (Zoom) recording to /home/<you>/.local/share/shepetal/meetings/<unix-ms>, system audio Some("<sink>.monitor")`, where `<sink>` is what `pactl get-default-sink` prints. `pgrep -a pw-record` shows two recorders: one ending in `Me.wav`, and one with `stream.capture.sink = true` ending in `Others.wav`.
4. While it records, run `shepetal probe`. Expected: a `mic user:` line for Zoom, and none for shepetal or `pw-record`. If one shows, write it down (docs/linux.md, known gaps).
5. Talk for about a minute while the other side talks too. Mute yourself in Zoom for 20 s, then unmute. Expected: no `meeting ended` line. If the recording ends, write down that Zoom closes its mic stream while muted (docs/linux-meetings.md, known gaps).
6. Leave the call. Expected about 4 to 6 s later: `shepetal: meeting ended, transcribing /home/<you>/.local/share/shepetal/meetings/<unix-ms>`, then `shepetal: meeting transcript /home/<you>/.local/share/shepetal/meetings/<unix-ms>/transcript.md`, and `pgrep -a pw-record` prints nothing. Write down how long the transcript took.
7. `transcript.md` opens by itself (L-MEET-11). Expected: `# Meeting`, `- Apps: Zoom`, `- Started: DD.MM.YY HH:MM` (the local time you clicked Record), `- Duration: N min` and `- Audio: Me.wav (microphone), Others.wav (system audio)`, then turns in time order: `[hh:mm:ss] Me: ...` with what you said and `[hh:mm:ss] Others: ...` with what the other side said, the times counted from the start of the recording.
(Automated: `starts_once_a_meeting_app_held_the_mic_for_the_grace`, `the_committed_pw_dump_fixture_is_a_meeting`, `the_prompt_has_one_record_button_and_expires_with_the_threshold`, `a_meeting_records_only_after_record_is_clicked`, `shepetal_own_streams_never_start_or_hold_a_meeting`, `flapping_restarts_the_grace_and_does_not_end_a_call`, `ends_after_reacquire_and_never_in_the_first_15_s`, `recorders_take_the_mic_and_the_default_sink_monitor`, `whisper_keeps_timestamps_and_drops_markers`, `transcript_interleaves_me_and_others_by_time`.)

### L-MEET-5: meeting audio is kept, owner-only
1. After L-MEET-4, `stat -c '%a %n' ~/.local/share/shepetal/meetings ~/.local/share/shepetal/meetings/<unix-ms> ~/.local/share/shepetal/meetings/<unix-ms>/*`. Expected: both folders are `700`, and `Me.wav`, `Others.wav` and `transcript.md` are `600`.
2. `file ~/.local/share/shepetal/meetings/<unix-ms>/*.wav`. Expected: both are `RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 16000 Hz`.
3. `pw-play` `Me.wav`. Expected: your voice for the whole call. `pw-play` `Others.wav`: the other side, without your voice.
4. `chmod 755 ~/.local/share/shepetal/meetings`, join a call and click Record. Expected: `shepetal: meeting not recorded: meeting folder: /home/<you>/.local/share/shepetal/meetings must be a 0700 directory`, no new folder, and `pgrep -a pw-record` prints nothing. Leave the call, then `chmod 700 ~/.local/share/shepetal/meetings`.
(Automated: `meeting_audio_is_owner_only_and_never_reused`, `recorders_take_the_mic_and_the_default_sink_monitor`.)

### L-MEET-6: no click, no recording
1. Join a call and close the notification without clicking Record. Expected: `shepetal: meeting not recorded: the Record? prompt was dismissed`. For the rest of the call: no new folder in `~/.local/share/shepetal/meetings/`, `pgrep -a pw-record` prints nothing, and no second notification. Leave the call.
2. Join a call and leave the notification alone. Expected about 20 s later: it goes from the screen and from the notification list, and `shepetal: meeting not recorded: Record was not clicked within 20 s`. Nothing is recorded. If the notification stays, write down `notify-send --version` (SIGINT did not close it). Leave the call.
3. Join a call, wait for the notification, and leave the call at once, without clicking. Expected about 15 s after the notification showed (before its 20 s are up): `shepetal: meeting ended before Record was clicked, nothing recorded`, and the notification goes away. Nothing is recorded.
(Automated: `a_dismissed_prompt_records_nothing_for_that_meeting`, `an_unanswered_prompt_is_withdrawn_and_records_nothing`, `the_prompt_is_withdrawn_when_the_call_ends_first`.)

### L-MEET-7: a headset switch and two meeting apps
1. Join a call, click Record, and switch to a Bluetooth headset (or plug one in) during it. Expected: no `meeting ended` line. After the call, `pw-play` `Others.wav`: the other side is there after the switch too.
2. Join a Zoom call and, in Firefox, a Google Meet call, and click Record once. Leave Zoom. Expected: no `meeting ended` line until you leave Meet too. One new meeting folder, and its `transcript.md` has an `- Apps:` line that names both `Zoom` and `Browser (Firefox)`.
(Automated: `a_device_change_holds_off_the_end_for_10_s`, `two_apps_are_one_meeting_until_both_let_go`.)

### L-MEET-8: the daemon killed mid-meeting
1. Join a call, click Record and talk for about 20 s. In another terminal run `pkill -9 -f 'shepetal daemon'`.
2. Expected about a second later: `pgrep -a pw-record` prints nothing. In the newest meeting folder, `pw-play` `Me.wav` and `Others.wav`: each plays up to the kill. There is no `transcript.md` (docs/linux-meetings.md, known gaps).
(Automated: `a_recorder_gets_sigint_when_the_daemon_goes`.)

### L-MEET-9: always record, and bad meeting settings
1. Put `{"meetings": {"auto_record": true}}` in `~/.config/shepetal/config.json` and start the daemon. Expected: `shepetal: meeting detection on, recording every meeting (meetings.auto_record), Thresholds { ... } ms (SHEPETAL_MEETING_THRESHOLDS)`.
2. Join a call. Expected within about 8 s: no notification, and the `meeting (Zoom) recording to` line. Leave the call. Expected: the `meeting ended` and `meeting transcript` lines as in L-MEET-4 step 6.
3. With `{"meetings": {"auto_record": "yes"}}`, run `shepetal daemon; echo $?`. Expected: `shepetal: /home/<you>/.config/shepetal/config.json: meetings.auto_record: expected true or false` and `1`.
4. Remove `~/.config/shepetal/config.json` and run `SHEPETAL_MEETING_THRESHOLDS=reacquire=soon shepetal daemon; echo $?`. Expected: `shepetal: SHEPETAL_MEETING_THRESHOLDS: "reacquire=soon": not a number of seconds` and `1`.
(Automated: `auto_record_is_opt_in`, `auto_record_records_without_asking`, `thresholds_are_tunable_in_seconds`.)

### L-MEET-10: a meeting without the Whisper model
On a machine where `shepetal probe` names a Parakeet model (CPU or CUDA):
1. `mv ~/.local/share/shepetal/ggml-large-v3-turbo-q5_0.bin ~/` and start the daemon. Expected: `shepetal: meetings are recorded but not transcribed until whisper-cli and /home/<you>/.local/share/shepetal/ggml-large-v3-turbo-q5_0.bin are installed`, then the `meeting detection on` line.
2. Join a call, click Record, talk, and leave. Expected: both WAVs are kept, the daemon prints `shepetal: meeting /home/<you>/.local/share/shepetal/meetings/<unix-ms>: Me was not transcribed: whisper-cli: ...` and the same for Others, and `transcript.md` lists `- Me was not transcribed: ...` and `- Others was not transcribed: ...` under its header, with no turns. It opens by itself, and the "Meeting transcript ready" notification says `Me was not transcribed: ...` and has only Open folder, no Copy transcript.
3. `mv ~/ggml-large-v3-turbo-q5_0.bin ~/.local/share/shepetal/`.
(Automated: `transcript_interleaves_me_and_others_by_time`, `the_ready_notification_offers_copy_only_with_speech_and_never_a_sound`.)

### L-MEET-11: the transcript window after a meeting
Before: `sudo apt install xdg-utils wl-clipboard xclip`, sound on, and a text editor (gedit or Text Editor) open with an empty document. Run it in "Ubuntu" (GNOME Wayland) and again in "Ubuntu on Xorg".
1. Join a call, click Record, talk with the other side for about a minute, then click into the empty document and keep typing while you leave the call with the mouse (or end it from the second device). Expected, when the daemon prints `meeting transcript .../transcript.md`: the transcript opens in your default text app, and a notification "Meeting transcript ready" shows `Zoom, DD.MM.YY HH:MM, N min` with the buttons Copy transcript and Open folder. No sound plays. Write down whether your typing kept going into the document or went to the transcript window (known gap in docs/linux-meetings.md); it must not go to the transcript window.
2. Before clicking anything, `wl-paste` (Wayland) or `xclip -o -selection clipboard` (X11). Expected: what was on the clipboard before, not the transcript.
3. Click Copy transcript. Expected: a short "Transcript copied" notification, with no sound. Paste into the document: one `[hh:mm:ss] Me: ...` or `[hh:mm:ss] Others: ...` line per turn, the same turns as in the window, without the `# Meeting` header.
4. In the transcript window, select a few words and press Ctrl+C, then paste. Expected: just those words.
5. Record a second call and leave it. Expected: a second window and a second notification, one each. Click Open folder on it (from the notification list if the banner went away). Expected: the file manager opens `~/.local/share/shepetal/meetings/<unix-ms>/` with `Me.wav`, `Others.wav` and `transcript.md`, and the clipboard still holds the first transcript.
6. Record a call where nobody speaks for 30 s (both sides muted), then leave. Expected: the window shows `No speech was recorded.` under the header, and the notification says `No speech was recorded.` and has only Open folder. Click it: the folder opens. If Whisper wrote words for the silence instead, write them down.
7. Record a call and leave the notification alone, then stop the daemon with Ctrl+C. Expected: the notification disappears from the notification list, and the transcript window stays open.
8. In "Ubuntu on Xorg": `sudo apt remove xclip && sudo apt install xsel`, record a call and click Copy transcript. Expected: "Transcript copied", and the turns paste. Then `sudo apt remove xsel`, record a call and click Copy transcript. Expected: "Transcript not copied: no wl-copy, xclip or xsel" and the same on the daemon's stderr after `shepetal: meeting transcript not copied:`. `sudo apt install xclip` afterwards.
(Automated: `a_meeting_records_only_after_record_is_clicked`, `auto_record_records_without_asking`, `the_transcript_window_copies_only_on_a_click`, `the_ready_notification_offers_copy_only_with_speech_and_never_a_sound`, `meeting_times_are_local_and_day_first`, `transcript_interleaves_me_and_others_by_time`, `clipboard_tool_follows_the_session`, `text_goes_over_stdin_not_argv`.)

## Windows

Setup: a Windows 11 PC with Shepetal installed from the CI run's `shepetal-windows-setup` artifact, and windows/README.md, "Hand test on a Windows 11 PC", done up to step 15 (a call is offered and recorded only after Record). Wear headphones (without them the other side is recorded in Me.wav too), and have a second device in the call to play the other side.

### W-MTG-1: the Meeting transcript window (F69, F120)
1. Copy a word in Notepad (Ctrl+C), so you can tell later whether the clipboard changed. Join a Zoom call in the Zoom app and click Record on the card. Say "Hello, can you hear me?", have the other side answer "Yes, loud and clear.", wait about 10 s, then say "I will send the notes on Friday." Leave the call after about a minute, click into Notepad and keep typing.
2. Expected: a few seconds after you leave, "Transcribing the meeting" shows next to the 🤫. Within a few minutes (write down how long), a "Meeting transcript" window opens in front of Notepad, with no sound. Notepad keeps the keyboard: its title bar stays active and your typing still lands in Notepad. Click into the window: only now does it take the focus.
3. Expected in the window: the first line is "Zoom · DD.MM.YY HH:MM · 1 min", with today's date and the time the recording started. Under it: "No summary: Shepetal for Windows does not summarize meetings yet." Then the turns in the order they were said, each with its time: "[00:00:..] Me: Hello, can you hear me?", "[00:00:..] Others: Yes, loud and clear." and, about 10 s later, "Me: I will send the notes on Friday." Copy summary is greyed out. No model name shows anywhere.
4. In Notepad press Ctrl+V. Expected: the word you copied in step 1, not the transcript.
5. Click Copy transcript. Expected: "Copied" next to the buttons, gone after about 2 s, and no sound. Ctrl+V in Notepad pastes the header and every turn with its time and speaker. Select one line in the window with the mouse and press Ctrl+C: Ctrl+V pastes only that line.
6. Click Open folder. Expected: Explorer opens `%LOCALAPPDATA%\Shepetal\meetings\<yyyyMMdd-HHmmss>` with Me.wav, Others.wav and transcript.md, and transcript.md holds the same text as Copy transcript. transcript.md > Properties > Security lists only your user.
7. Close the window (its X, or Esc). Record two short meetings one after the other (join, Record, say a sentence, leave, then the same again). Expected: one window, which shows the second meeting once it is transcribed, never two windows.
8. Join a call, click Record, stay silent with the other side muted for about 20 s, and leave. Expected: the window says "No speech was recorded." under the header, and Open folder still opens that meeting's folder.
(Automated: `the_window_shows_it_and_copies_only_on_a_click`, `copy_summary_stays_off_until_there_is_a_summary`, `a_newer_meeting_replaces_the_text_of_the_one_window`, `no_speech_says_so_and_still_opens_the_folder`, `the_window_never_takes_the_focus_on_its_own`, `a_channel_splits_into_its_stretches_of_speech`.)
