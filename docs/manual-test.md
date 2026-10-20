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

## Linux

Setup: a real Ubuntu 24.04 desktop, not a VM without a keyboard of its own. Log in to each session from the gear at the bottom right of the login screen: "Ubuntu" is GNOME on Wayland (the default), "Ubuntu on Xorg" is X11, and "Plasma (Wayland)" is KDE once `sudo apt install kde-plasma-desktop` is installed (keep gdm3 when asked). `echo $XDG_SESSION_TYPE $XDG_CURRENT_DESKTOP` tells you which one you are in. The gesture and audio steps (L-FN, L-AUD) behave the same in every session because evdev sits below the display server, so run them once. The L-INS steps run once per session.

What is not on main yet, so not tested here: the 🤫 indicator (#56; the short-press hint goes to the daemon's stderr), rule 8 focus checks (#58; text goes to whatever window has focus when it is ready), history (#67), Esc cancel in hands-free, retention, and meeting recording (detection only runs in `probe`). Keep the terminal that runs `shepetal daemon` visible: its stderr is the only feedback.

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
(Automated: `hold_of_500ms_is_push_to_talk`, `release_at_499ms_is_a_tap_not_a_stop`, `second_press_after_window_starts_fresh`, `evdev_key_values_become_gesture_events`, `a_key_event_is_stamped_when_it_arrives`, `dictation_keeps_the_audio_the_model_heard`.)

### L-FN-2: double-tap for hands-free
1. Tap fn twice quickly (the second press within half a second of releasing the first) and release.
2. Speak for about 20 s without holding anything. Meanwhile type a few words into the document. Expected: the typing does not stop the recording.
3. Click back to where the text should go and press fn once.
4. Expected: the whole spoken passage is typed there. The daemon prints no hint.
(Automated: `double_tap_gap_is_500ms`, `double_tap_inside_window_is_hands_free_until_next_press`.)

### L-FN-3: too-short press and its hint
1. Tap fn once, briefly (under half a second), and don't tap again.
2. Expected: nothing is typed. About half a second after the release the daemon prints `shepetal: hint: Hold fn to talk · double-tap for hands-free` (with the L-KEY-3 key's name in place of fn). A new `<unix-ms>.tooshort.wav` is in `~/.local/share/shepetal/audio/`.
3. Tap fn and type a word right after it. Expected: the same hint, nothing transcribed.
4. Tap fn and then hold a letter key down so it repeats. Expected: the hint still comes about half a second after the tap, not when you let go of the letter.
(Automated: `single_tap_is_too_short_once_window_expires`, `typing_after_a_tap_is_still_too_short`, `a_tap_ends_as_too_short_on_time_while_a_key_repeats`, `too_short_press_keeps_the_clip_and_shows_the_hint`.)

### L-FN-4: chords and Esc
1. Hold fn and press F1 (on an Apple keyboard, fn+F1 is F1 or brightness down, depending on `fnmode`). Expected: nothing is typed, no hint is printed, and a new `<unix-ms>.cancelled.wav` is in the audio folder.
2. In a long document hold fn and press Left or Down arrow. Expected: the arrow does its fn action (Home or Page Down) or moves the cursor, nothing is typed, no hint, one more `.cancelled.wav`.
3. Hold fn, say a few words, and press Esc while still holding. Expected: the same as step 1: Esc while the hotkey is down is a chord and cancels.
4. Hold fn for about 2 s while speaking, then press Down arrow. Expected: also cancelled, nothing is typed. (Linux cancels at any point of the hold; the Mac only in the first second. Known gap in docs/linux.md.)
5. Double-tap fn for hands-free, speak, and press Esc. Expected: nothing happens; the recording goes on, and fn types it. Esc cancel for hands-free is not built on Linux (F03).
6. With both an Apple keyboard and the laptop keyboard: hold fn on the Apple keyboard and press a key on the laptop keyboard. Expected: no cancel, the hold is typed on release (only keyboards that can send the hotkey are read; known gap).
(Automated: `chord_with_another_key_cancels`, `cancel_keeps_the_recording`.)

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

### L-INS-1: ydotool on GNOME Wayland
1. In the "Ubuntu" session, with `ydotoold` running (L-SETUP-4), start `shepetal daemon`. Expected: its first line ends with `insert Ydotool`.
2. In the GNOME Text Editor hold fn and say "Send the report today, then call Anna."
3. Expected: the sentence is typed at the cursor, with the comma and the period. Repeat in GNOME Terminal and in a Firefox text field: the same.
4. ydotool sends keycodes, so the result depends on the layout. With a non-US layout (for example German), write down any swapped letters (y/z) or wrong punctuation.
5. Stop ydotoold and dictate again. Write down what happens: ydotool 0.1.8 may still type without the daemon (it prints `ydotoold backend unavailable`), or the daemon prints `shepetal: insert: ydotool failed: …` and nothing is typed. v0 does not fall back to the clipboard after a failure; the clip is still kept.
(Automated: `gnome_wayland_skips_wtype`, `text_goes_over_stdin_not_argv`.)

### L-INS-2: wtype on KDE Wayland
1. In "Plasma (Wayland)", start `shepetal daemon`. Expected: `insert Wtype`.
2. In Kate hold fn and say "Send the report today, then call Anna."
3. Expected: the sentence is typed at the cursor. If nothing is typed and the daemon prints `shepetal: insert: wtype failed: …` (for example "Compositor does not support the virtual keyboard protocol"), write it down with `plasmashell --version`: KWin may refuse wtype, and v0 does not fall back to ydotool after a failure.
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
3. Expected: nothing is typed. Ctrl+V pastes the sentence, not "earlier" (the old clipboard is not restored, docs/linux.md). The daemon prints no paste hint yet (#58).
4. On X11: `sudo apt remove xdotool ydotool`. Expected: `Some(Xclip)`, and steps 2 and 3 give the same result.
5. Remove `wl-clipboard` and `xclip` too and start the daemon. Expected: it exits with `shepetal: no text insertion tool: install wtype, xdotool, ydotool, wl-clipboard or xclip`.
6. `sudo apt install wtype xdotool ydotool wl-clipboard xclip` again.
(Automated: `ydotool_then_clipboard_are_fallbacks`, `text_goes_over_stdin_not_argv`.)

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
