# Linux shortcuts

The Linux daemon's keys besides the dictation hotkey live in `linux/src/shortcuts.rs`. They read
the same evdev events as the hotkey (`watch_keys` in `linux/src/main.rs`). Wispr's behavior is in
docs/re/dictation-input.md, sections 1, 2.3 and 2.4.

| Key | Default | What it does |
| --- | --- | --- |
| Esc | Esc (fixed) | Cancels a dictation in progress: nothing is transcribed or typed, and the audio is kept as `<stamp>.cancelled.wav` (goal rule 4). With nothing recording, Esc does nothing. |
| paste_last | Shift+Alt+Z | Types the newest dictated text in the history (docs/linux.md, "History, retention and paste last") at the cursor again, once every key of the combo is up, so the held Shift and Alt do not change the typed text. If typing fails, the text goes on the clipboard with the `Typing failed. ...` hint. |
| copy_last | Shift+Alt+X | Puts the newest dictated text on the clipboard (wl-copy, else xclip or xsel), the same way. |
| hands_free | Ctrl+Meta+Space | Starts a hands-free dictation. The next press stops and transcribes it; a press within 500 ms of the start cancels it. The hotkey and Esc end it too. |
| (cap) | 19 / 20 min | At 19 min the hint "Recording stops in 1 minute" shows; at 20 min the dictation stops and is transcribed as usual. |

The paste and copy defaults are Wispr's Windows defaults; the hands-free one is Wispr's Windows
Ctrl+Win+Space. Hold fn and double-tap fn work as before.

## Config

`$XDG_CONFIG_HOME/shepetal/config.json`, else `~/.config/shepetal/config.json`. It is the
daemon's one settings file: the 24 h retention setting goes in the same file.

```json
{
  "shortcuts": {
    "paste_last": "shift+alt+z",
    "copy_last": "shift+alt+x",
    "hands_free": "ctrl+meta+space"
  }
}
```

Any shortcut left out keeps its default; other settings in the file are skipped. The daemon
refuses to start, naming the file, the shortcut and the reason, when the file is not valid JSON
(with the line and column), or when a combo:

- has more than 3 keys;
- has no modifier (ctrl, alt, shift, meta; `left`/`right` prefixes pick one side), or not
  exactly one other key (a letter, digit, `f1`-`f24`, `space`, `tab`, `enter`, arrows and so on,
  or an evdev code number);
- names the same modifier twice, such as `leftalt+rightalt+z`;
- uses Esc, or the dictation hotkey (for example `fn+z`, or `rightalt+z` with
  `SHEPETAL_KEY=rightalt`). A generic `alt` with Right Alt as the hotkey means Left Alt only, so
  the defaults still work with that hotkey;
- is the same key set as another shortcut;
- or when `shortcuts` has an unknown name or a value that is not a string.

## Limits

- **Nothing is swallowed.** shepetal reads evdev without a grab, so the focused app also gets Esc
  and the shortcut keys. Wispr swallows Esc while dictating; on Linux that needs a uinput
  re-injection proxy (docs/re/dictation-input.md, section 3). With nothing recording, Esc reaches
  the app as normal, which is what we want there.
- **Only the keyboards that can send the hotkey are read.** A shortcut typed on another keyboard
  is not seen.
- **A key-up lost while shepetal was not reading** (for example across a suspend) leaves that key
  counted as held, so a combo does not match until the key is pressed and released again. Wispr
  reconciles stale keys; this does not yet.

## Hand test (L-SC)

Run `shepetal daemon` in a terminal on a desktop session, with a text editor focused.

1. Double-tap fn, say a sentence, wait 2 s, press Esc. Expected: nothing is typed; the editor
   also receives the Esc; `ls ~/.local/share/shepetal/audio` shows a new `*.cancelled.wav` that
   plays the sentence.
2. With nothing recording, press Esc in a dialog that closes on Esc. Expected: the dialog closes
   and the terminal shows nothing from shepetal.
3. Dictate a sentence, then press Shift+Alt+Z in another text field. Expected: the sentence is
   typed after you let go of the keys. Press Shift+Alt+X, then Ctrl+V. Expected: the same text.
4. Press Ctrl+Meta+Space, speak, press it again. Expected: the text is typed. Press it twice
   quickly. Expected: nothing is typed and a `*.cancelled.wav` is kept.
5. Put `{"shortcuts": {"paste_last": "z"}}` in `~/.config/shepetal/config.json` and start the
   daemon. Expected: it exits with `...config.json: paste_last: "z" needs a modifier: ctrl, alt,
   shift or meta`.
6. Start a hands-free dictation and leave it for 20 min. Expected: "Recording stops in 1 minute"
   at 19 min, then the text is typed at 20 min.
