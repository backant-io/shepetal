# Linux: personal dictionary and snippets

Code: `linux/src/vocab.rs`. Behavior follows docs/re/text-pipeline.md (§2 step 6, §4 "Deterministic rules") and the Mac `Vocabulary` format, so one `dictionary.txt` works on both.

## Files

Both live in `$XDG_CONFIG_HOME/shepetal/` (default `~/.config/shepetal/`, dir 0700, files 0600) and are re-read on every dictation. The CLI writes them through an owner-only temp file and a rename; loading a file makes it 0600 again.

`dictionary.txt`, one entry per line:

```
GitHub              a word or phrase: biases the model and fixes its casing in the text
btw => by the way   a replacement
*Shepetal           a leading * stars an entry: starred entries go first in the model hint
# comment
```

`snippets.toml`, one TOML pair per line: `"my address" = "221B Baker Street\nLondon"`.

## CLI

```
shepetal dict add GitHub
shepetal dict add 'btw => by the way'
shepetal dict remove btw
shepetal dict list
shepetal snippet add 'my address' '221B Baker Street'
shepetal snippet remove 'my address'
shepetal snippet list
```

Adding an entry or trigger that exists (case-insensitive) replaces it.

## Pipeline

1. **Bias**: with Whisper, the dictionary's spoken side (starred first, at most 200 entries) goes to `whisper-cli --prompt`. sherpa-onnx models get no hint yet (their hotwords need modified beam search).
2. **Whole-dictation snippet**: if the transcript, with case and punctuation ignored, equals a trigger, the expansion is inserted alone.
3. **Inline**: snippet triggers and dictionary entries are replaced in one pass: case-insensitive, whole words only (Unicode letters and digits count as word characters, so `btw` inside `btwx` never fires), any whitespace between the words of a phrase, longest first, and inserted text is never scanned again. A replacement at a capital keeps it (`Btw` -> `By the way`); a plain entry is written exactly as stored (`github` -> `GitHub`).

Tests: `cargo test vocab` and `the_dictionary_biases_whisper_and_fixes_the_text` in `linux/src/main.rs`.
