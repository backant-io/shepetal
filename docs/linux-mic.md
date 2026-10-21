# Linux: mic selection and mic health

Code: `linux/src/mic.rs`. Behavior source: `docs/re/dictation-input.md` (mic selection, dead-mic
check, MicDisconnected).

## Which mic records

At every record start the daemon lists the input sources and records from the best one
(`pw-record --target <node.name>`, or `parecord --device=<name>`).

- **Sources** come from `pw-dump` (`Audio/Source` nodes, with `device.bus` and
  `device.form-factor` from their Device object), else from `pactl -f json list sources`
  (PulseAudio 16+). Sink monitors and virtual sources (echo cancel, loopbacks) are not mics and
  are left out.
- **Ranking**, best first:
  1. the user's list, in its order: `[mic] prefer = [...]` in
     `$XDG_CONFIG_HOME/shepetal/config.toml` (default `~/.config/shepetal/config.toml`). Each
     entry is a case-insensitive substring of the source's name or description:

     ```toml
     [mic]
     prefer = ["Jabra", "Yeti"]
     ```
  2. the desktop's default source;
  3. other external mics (USB, Bluetooth), by node name;
  4. the built-in mic (form factor `internal`, or on the pci/platform bus).
- **Lid closed** (every `/proc/acpi/button/lid/*/state` says `closed`): the built-in mic goes
  last of all, even when it is preferred, so it records only when nothing else is plugged in.
  A machine without that file (a desktop, or a lid driver that does not report) counts as open.
- **Hot-plug:** the pick is made again from a fresh list at each record start, so a mic plugged
  in or removed between dictations is used at once. When the pick changes, the hint
  `Mic: <name> (ranked higher | the last one is gone)` shows next to 🤫. The source is never
  swapped inside a dictation, so a clip never changes mic mid-sentence.

`shepetal mics` (or `shepetal mics --pw-dump FILE`) prints the sources in this order, marks the
one that would record with `*`, and says why each sits where it does.

## Health alerts

While recording, a watcher reads the growing WAV every 0.5 s and the source list every 2 s.

| Alert | When |
| --- | --- |
| No sound from the mic | The samples have been exactly zero for more than 5 s. Quiet speech is never all zero; a run of pure zeros is a dead or hardware-muted mic. Once per run. |
| Mic disconnected | The source being recorded disappears. The recorder is stopped with SIGINT, so the WAV stays valid, and what was said before is transcribed and kept. |
| Cannot read the mic | No new samples for 5 s while the recorder runs (the device stopped delivering, or the WAV cannot be read). The recorder is stopped with SIGINT and what was said before is transcribed and kept, as for a disconnect. |
| No PipeWire or PulseAudio | Neither `pw-dump` nor `pactl` answers at record start. |
| Bluetooth mic (advice) | The mic picked at a record start is on the Bluetooth bus and another mic (not Bluetooth, not the built-in one under a closed lid) could take its place. A Bluetooth headset records in its call profile (HSP/HFP: narrowband, and its playback drops to call quality too). Once per daemon run. |
| Lid closed (advice) | The lid is closed and the built-in mic is the one picked, so nothing else is plugged in. Once per daemon run. |

Each alert is a desktop notification (`notify-send`) with the whole text, and a few words next
to 🤫 (`error No sound from the mic`, `error Mic disconnected`, `error Cannot read the mic`,
`error No PipeWire or PulseAudio` on the daemon's indicator socket; the advice as `hint
Bluetooth mic: lower quality` and `hint Lid closed: mic muffled`, so 🤫 does not turn yellow),
and the whole text on stderr. There are no sounds. The same kind
shows at most once a minute. When the mic is unplugged mid-dictation, the dictation ends right
there: what was said is typed without another press, and the next press starts a new one.

## Hand test (real desktop)

1. Write `[mic]\nprefer = ["<part of your USB mic's name>"]` to `~/.config/shepetal/config.toml`.
   `shepetal mics` lists the USB mic first with `*`.
2. Unplug it: `shepetal mics` now shows the next one first. Dictate: the hint says the mic
   changed, and the text arrives.
3. Plug it back in and dictate again: the hint says `ranked higher`.
4. Start a hands-free dictation on the USB mic and unplug it: a notification says the mic was
   disconnected, the recording stops, and what was said before is typed.
5. Mute the mic in hardware (or `pactl set-source-mute <name> 1`) and dictate for 7 s: one
   "No sound" notification after about 5 s, and no second one within a minute.
6. On a laptop with an external mic, close the lid (external display) and run `shepetal mics`:
   the built-in mic is last with `lid closed`.
7. `systemctl --user stop pipewire pipewire-pulse wireplumber` and press fn: the
   "No PipeWire or PulseAudio" notification shows. Start them again.
8. The mic that stops delivering, the Bluetooth headset and the lid closed on the only mic are
   L-MIC-7 to L-MIC-9 in docs/manual-test.md.

## Known gaps

- The source list is polled, not followed through `pw-dump --monitor` events, so a disconnect
  is noticed within about 2 s.
- The Mac also warns again at 15 s of zeros, reopens the mic once after a silent first second,
  and suggests a closer mic for a quiet recording; Linux does not yet.
- The Bluetooth and lid advice is shown once per daemon run, not once ever as on the Mac.
- Whether `/proc/acpi/button/lid` is present depends on the laptop's ACPI tables. Some newer
  machines report the lid only through `SW_LID` on an input device, which is not read yet.
