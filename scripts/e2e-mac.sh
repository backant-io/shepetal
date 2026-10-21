#!/bin/bash
# End-to-end check of the Mac pipeline on speech made with `say`: capture resampler -> local STT ->
# cleanup (rules, then the local model on self-corrections and lists) -> audio store + history ->
# pasteboard + Cmd+V into a text view the app owns.
# The test shows no window, never takes focus, and uses a private pasteboard, never the user's clipboard.
# Asserts WER <= 8 %, text ready <= 700 ms after release (800 ms for c05, below), an owner-only audio file
# per recording, and that history kept the app, bundle id and page URL given for each dictation. The page-URL lookup must
# return at once and do its work off the main thread. Each clip is then re-transcribed from its kept WAV,
# as History's re-transcribe does, and must give the same text and the engine's model name on the same row.
# A dictionary.txt in the test's own data dir replaces one word of e03; that clip is checked for the replacement
# and left out of the WER. The data dir is .cache/e2e/home, or E2E_HOME; an exported SHEPETAL_HOME is ignored.
# A separate run on 2 s of digital silence must paste nothing and keep the audio as "no_speech".
# short.wav is the loudest 200 ms of e01: Parakeet refuses under 300 ms, so the engine must pad it, and a
# clip that short must never end as "Transcription failed" (a quick hold used to).
# e01-quiet is e01 at -40 dB (loudest 100 ms about -52 dBFS): it must still be inserted word for word,
# so a speech floor set too high fails here.
# Run it offline to prove transcription makes no network call:
#   sandbox-exec -p '(version 1)(allow default)(deny network*)' scripts/e2e-mac.sh
# ENGINE=fallback runs the whisper.cpp fallback instead of Parakeet (the latency bar applies to the
# default model only).
# The c* clips need the local cleanup model: SHEPETAL_CLEANUP_MODEL (default: Qwen3.5 2B in bench/.cache/cleanup,
# downloaded there on the first run, about 1.3 GB, so run once with the network on). CLEANUP=rules skips them
# and says so.
# c05 (F24): c04 dictated into a field with 596 characters on each side of the cursor, with "Use the text around
# the cursor" on (the default), under an 800 ms bar (Pavel, 2026-10-21; it took 726 to 800 ms on the M4 Pro, #235);
# the field must be read, and read before cleanup ends. FIELD=0 skips it.
# Languages (F12), last: with English and Japanese chosen, whisper large-v3-turbo runs in process on e01 and on j01,
# Japanese made with `say -v Kyoko`, and each must come out in its own language. With English and Korean chosen,
# whisper hears j01 as Japanese first and must still be told one of the two (#31). Then Parakeet, with German and
# French chosen, on e02: the English text is kept and the wrong-language hint names English. The whisper model is
# SHEPETAL_WHISPER_MODEL (default: bench/.cache/whisper, downloaded there on the first run, about 574 MB).
# LANGUAGES=skip skips this part and says so.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=${SHEPETAL_BIN:-.build/release/shepetal}
[ -x "$BIN" ] || swift build -c release
# The cleanup model's and whisper's libraries link no socket or DNS call, so they cannot reach the network even
# when a failed call would be swallowed (the sandboxed run below only shows that nothing breaks without the network).
for LIB in llama whisper; do
  F=$(dirname "$BIN")/$LIB.framework/$LIB
  [ -f "$F" ] || F=$(dirname "$BIN")/../Frameworks/$LIB.framework/$LIB
  [ -f "$F" ] || { echo "no $LIB.framework next to $BIN" >&2; exit 1; }
  if nm -u "$F" | grep -Eq '^_(socket|connect|getaddrinfo|gethostbyname|curl_[a-z_]+)$'; then
    echo "$F links network calls" >&2; exit 1
  fi
  echo "$LIB.framework: no network calls linked"
done
WORK=$PWD/.cache/e2e
FIX=$WORK/fixtures
# Never the user's data dir, even when SHEPETAL_HOME is exported: E2E_HOME moves the test's own.
export SHEPETAL_HOME=${E2E_HOME:-$WORK/home}
mkdir -p "$FIX" "$SHEPETAL_HOME"
rm -f "$FIX"/c*.gone "$FIX"/c*.field "$FIX"/c05.*  # c05 is made from c04 unless FIELD=0
DICT=$SHEPETAL_HOME/dictionary.txt
if [ -e "$DICT" ] && ! head -1 "$DICT" | grep -q '^# e2e-mac'; then
  echo "e2e-mac: $DICT is not ours, refusing to overwrite it" >&2; exit 1
fi
printf '# e2e-mac dictionary\ndentist => orthodontist\n' > "$DICT"

while IFS='|' read -r id voice text; do
  [ -f "$FIX/$id.wav" ] || say -v "$voice" --data-format=LEI16@44100 -o "$FIX/$id.wav" "$text"
  printf '%s\n' "$text" > "$FIX/$id.txt"
done <<'FIXTURES'
e01|Samantha|Please send the quarterly report to the design team before Friday afternoon, and copy the finance lead on the thread.
e02|Daniel|The deployment finished without errors, but the staging database still needs a fresh backup tonight.
e03|Samantha|Remind me to call the dentist tomorrow morning and to pick up groceries on the way home.
e04|Daniel|Our new onboarding flow cut the average setup time in half, so let's share the results at the next team meeting.
e05|Samantha|I reviewed the pull request this morning. The tests pass on my machine, but the build on the integration server keeps timing out, so we should look at the cache settings before we merge anything else.
e06|Daniel|Could you move our weekly sync to Thursday afternoon, since half of the team is traveling on Wednesday?
FIXTURES

# e01 scaled by -40 dB, written as 32-bit float so the quiet samples keep their resolution.
python3 - "$FIX/e01.wav" "$FIX/e01-quiet.wav" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1])
assert (w.getnchannels(), w.getsampwidth()) == (1, 2), "say writes 16-bit mono"
rate, n = w.getframerate(), w.getnframes()
x = [v / 32768 * 10 ** (-40 / 20) for v in struct.unpack(f"<{n}h", w.readframes(n))]
win = rate // 10
loudest = max(math.sqrt(sum(v * v for v in x[i:i + win]) / win) for i in range(0, n - win, win))
db = 20 * math.log10(loudest)
assert -56 < db < -48, f"quiet clip at {db:.1f} dBFS"
data = struct.pack(f"<{n}f", *x)
hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, 1, rate, rate * 4, 4, 32)
open(sys.argv[2], "wb").write(hdr + b"data" + struct.pack("<I", len(data)) + data)
print(f"e01-quiet.wav: loudest 100 ms window {db:.1f} dBFS")
PY
cp "$FIX/e01.txt" "$FIX/e01-quiet.txt"

# Cleanup clips: spoken text | the text the model should make of it | words that must be gone.
CLIPS=("$FIX"/e*.wav)
if [ "${CLEANUP:-}" = rules ]; then
  echo "SKIPPED: cleanup clips (CLEANUP=rules)"
else
  export SHEPETAL_CLEANUP_MODEL=${SHEPETAL_CLEANUP_MODEL:-$PWD/bench/.cache/cleanup/Qwen3.5-2B-Q4_K_M.gguf}
  [ -f "$SHEPETAL_CLEANUP_MODEL" ] ||
    CLEANUP_MODELS=$(dirname "$SHEPETAL_CLEANUP_MODEL") bench/cleanup/run.sh --fetch "$(basename "$SHEPETAL_CLEANUP_MODEL")" ||
    { echo "no cleanup model at $SHEPETAL_CLEANUP_MODEL and the download failed (run once with the network on, or CLEANUP=rules)" >&2; exit 1; }
  while IFS='|' read -r id voice text expected gone; do
    [ -f "$FIX/$id.wav" ] || say -v "$voice" --data-format=LEI16@44100 -o "$FIX/$id.wav" "$text"
    printf '%b\n' "$expected" > "$FIX/$id.txt"
    printf '%s\n' "$gone" > "$FIX/$id.gone"
    CLIPS+=("$FIX/$id.wav")
  done <<'CLEANUP'
c01|Samantha|Let's move the review to Tuesday, actually Wednesday, at four.|Let's move the review to Wednesday at four.|tuesday actually
c02|Daniel|Send the contract to Laura, I mean Linda, before lunch.|Send the contract to Linda before lunch.|laura mean
c03|Samantha|We need three things for the trip. First, the tickets. Second, the hotel booking. Third, the travel insurance.|We need three things for the trip:\n1. The tickets\n2. The hotel booking\n3. The travel insurance|first second third
c04|Daniel|I think we should ship the new search page on Monday, no wait, on Thursday, so the support team has enough time to read the new docs and test the export with a few customers.|I think we should ship the new search page on Thursday, so the support team has enough time to read the new docs and test the export with a few customers.|monday wait
CLEANUP
  if [ "${FIELD:-1}" = 1 ]; then
    # F24: c05 is c04 dictated into a full field (596 characters on each side of the cursor) with the text around
    # the cursor on, so the 800 ms bar covers the most context the model gets. E2E reads c05.field: before, a tab, after.
    for ext in wav txt gone; do cp "$FIX/c04.$ext" "$FIX/c05.$ext"; done
    python3 -c 'import sys; s = "The venue holds about eighty people, and the caterer wants the final count by noon the day before. " * 6
open(sys.argv[1], "w").write(s + "\n\n\t\n\n" + s)' "$FIX/c05.field"
    CLIPS+=("$FIX/c05.wav")
  fi
fi

# A clip with an error exits 1; the checks below name it.
"$BIN" --e2e "${CLIPS[@]}" ${ENGINE:+--engine "$ENGINE"} 2>"$WORK/stderr.log" | tee "$WORK/results.jsonl" || true

# Silence exits 1 by design ("No speech heard"); the checks below read its JSON line.
python3 -c 'import sys, wave; w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(64000)); w.close()' "$FIX/silence.wav"
"$BIN" --e2e "$FIX/silence.wav" ${ENGINE:+--engine "$ENGINE"} 2>>"$WORK/stderr.log" | tee "$WORK/silence.jsonl" || true

python3 - "$FIX/e01.wav" "$FIX/short.wav" <<'PY'
import struct, sys, wave
w = wave.open(sys.argv[1])
rate, n = w.getframerate(), w.getnframes()
x = struct.unpack(f"<{n}h", w.readframes(n))
win = rate // 5
start = max(range(0, n - win, rate // 50), key=lambda i: sum(v * v for v in x[i:i + win]))
o = wave.open(sys.argv[2], "wb"); o.setnchannels(1); o.setsampwidth(2); o.setframerate(rate)
o.writeframes(struct.pack(f"<{win}h", *x[start:start + win])); o.close()
PY
"$BIN" --e2e "$FIX/short.wav" ${ENGINE:+--engine "$ENGINE"} 2>>"$WORK/stderr.log" | tee "$WORK/short.jsonl" || true

python3 - "$WORK/results.jsonl" "$FIX" "$DICT" "$WORK/silence.jsonl" "$WORK/short.jsonl" <<'PY'
import json, os, re, stat, struct, sys

def words(s):
    return re.sub(r"[^a-z0-9' ]+", " ", s.lower().replace("-", " ")).split()

def edits(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]

assert edits("a b c".split(), "a x c d".split()) == 2  # self-check of the WER math

results, fix, dictionary = sys.argv[1:4]
replaced = {"e03.wav": ("dentist", "orthodontist")}  # clip -> what dictionary.txt replaces; kept out of the WER
assert stat.S_IMODE(os.stat(dictionary).st_mode) == 0o600, "dictionary.txt is not owner-only"
rows = [json.loads(l) for l in open(results) if l.strip()]
assert rows and all("wav" in r for r in rows), f"no results: {rows}"
# The batch exits 1 when a clip has an error, so its exit code is ignored above; every clip must have a row,
# or a run that died partway would pass on the clips it finished.
ran = sorted(os.path.basename(r["wav"]) for r in rows)
clips = r"(e\d\d(-quiet)?|c\d\d)" if os.environ.get("CLEANUP") != "rules" else r"e\d\d(-quiet)?"
want = sorted(f for f in os.listdir(fix) if re.fullmatch(clips + r"\.wav", f))
assert ran == want and "e01-quiet.wav" in want, ("clips missing from the run", sorted(set(want) - set(ran)), ran)
errors = ref_words = 0
for r in rows:
    name = os.path.basename(r["wav"])
    assert r["error"] == "", (name, r["error"])
    ref = words(open(os.path.join(fix, name[:-4] + ".txt")).read())
    e = edits(ref, words(r["inserted_text"]))
    if name in replaced:
        spoken, written = replaced[name]
        got = words(r["inserted_text"])
        assert written in got and spoken not in got, (name, "dictionary replacement missing", r["inserted_text"])
    else:
        errors += e; ref_words += len(ref)
    if name == "e01-quiet.wav":
        assert e == 0, (name, "quiet speech lost words", r["error"], r["inserted_text"])
    assert r["inserted_text"] == r["text"], (name, "field holds something else", r["inserted_text"])
    assert r["paste_landed"] and r["clipboard_restored"], (name, "paste", r)
    assert r["pasteboard"].startswith("io.backant.shepetal.e2e."), (name, "not the private pasteboard", r["pasteboard"])
    assert not r["window_visible"], (name, "the test put a window on screen")
    field = os.path.join(fix, name[:-4] + ".field")
    if not os.environ.get("ENGINE"):  # F24's field costs time: Pavel set its bar to 800 ms (2026-10-21)
        assert r["ready_ms"] <= (800 if os.path.exists(field) else 700), (name, "slow", r["ready_ms"])
    p = r["audio_path"]
    st = os.stat(p)
    assert stat.S_IMODE(st.st_mode) == 0o600, (name, oct(st.st_mode))
    assert stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode) == 0o700, name
    assert not p.startswith(("/tmp", "/private/tmp")), p
    assert r["history_outcome"] == "inserted" and r["history_audio_path"] == p, (name, r["history_outcome"])
    app = (r["history_app"], r["history_bundle_id"], r["history_url"])
    assert app == ("E2E Browser", "com.apple.Safari", "https://example.com/e2e/page"), (name, "app at dictation start", app)
    assert r["app_resolve_ms"] < 100, (name, "page-URL lookup held the main thread", r["app_resolve_ms"])
    if os.path.exists(field):  # F24: the model got the field (re-transcribing has none, so its text may differ)
        assert r["field_chars_read"] >= 1000, (name, "the field was not read", r["field_chars_read"])
        assert r["field_read_ms"] < r["ready_ms"], (name, "the field was read after cleanup", r["field_read_ms"])
    else:
        assert r["retranscribed_text"] == r["text"], (name, "re-transcribe", r)
    assert r["retranscribed_row_kept"], (name, "re-transcribe", r)
    assert r["retranscribed_model"] == r["model"], (name, "re-transcribe model", r["retranscribed_model"])
    data = open(p, "rb").read()
    fmt, ch, rate = struct.unpack("<HHI", data[20:28])
    assert (fmt, ch, rate) == (3, 1, 16000), (name, fmt, ch, rate)
    assert abs((len(data) - 44) / 4 / 16000 - r["audio_seconds"]) < 1e-3, name
    gone = os.path.join(fix, name[:-4] + ".gone")
    if os.path.exists(gone):  # a cleanup clip: the model rewrote it and the taken-back words are gone
        assert r.get("cleanup_model"), (name, "cleanup model not used", r.get("cleanup_status"), r["text"])
        left = set(open(gone).read().split()) & set(words(r["inserted_text"]))
        assert not left, (name, "taken-back words left", left, r["inserted_text"])
    print(f"{name}: {e}/{len(ref)} word errors, ready {r['ready_ms']} ms, {r['audio_seconds']:.1f} s audio, "
          f"cleanup {r.get('cleanup_model') or 'rules'}")
wer = errors / ref_words
print(f"model {rows[0]['model']}: WER {wer:.1%} over {len(rows) - len(replaced)} clips ({ref_words} words), "
      f"dictionary replacement in {', '.join(replaced)}")
assert wer <= 0.08, f"WER {wer:.1%} > 8%"

(s,) = [json.loads(l) for l in open(sys.argv[4]) if l.strip()]
assert s["error"] == "No speech heard" and s["history_outcome"] == "no_speech", s
assert s["inserted_text"] == "" and not s["paste_landed"], ("silence pasted something", s)
assert s["pasteboard_text"] == "" and not s["window_visible"], ("silence touched the clipboard or showed a window", s)
assert stat.S_IMODE(os.stat(s["audio_path"]).st_mode) == 0o600, s["audio_mode"]
assert stat.S_IMODE(os.stat(os.path.dirname(s["audio_path"])).st_mode) == 0o700, s["audio_dir_mode"]
assert s["history_audio_path"] == s["audio_path"], s
data = open(s["audio_path"], "rb").read()
assert abs(s["audio_seconds"] - 2) < 0.05 and abs((len(data) - 44) / 4 / 16000 - s["audio_seconds"]) < 1e-3, s
assert set(data[44:]) == {0}, "the kept WAV must hold the silent samples the guard saw"
print(f"silence.wav: outcome {s['history_outcome']}, inserted_text {s['inserted_text']!r}, audio {s['audio_mode']} in a {s['audio_dir_mode']} dir")

(c,) = [json.loads(l) for l in open(sys.argv[5]) if l.strip()]
assert c["audio_seconds"] < 0.3, ("short.wav is not under Parakeet's 300 ms minimum", c["audio_seconds"])
assert not c["error"].startswith("Transcription failed"), ("a short clip reached the model unpadded", c["error"])
assert c["history_outcome"] in ("inserted", "no_speech") and c["history_audio_path"] == c["audio_path"], c
assert stat.S_IMODE(os.stat(c["audio_path"]).st_mode) == 0o600, c
print(f"short.wav: {c['audio_seconds']:.2f} s, outcome {c['history_outcome']}, error {c['error']!r}")
PY

# A paste that does not land (the target lost focus) must leave the text on the clipboard.
"$BIN" --e2e "$FIX/e01.wav" --drop-paste ${ENGINE:+--engine "$ENGINE"} 2>>"$WORK/stderr.log" > "$WORK/dropped.jsonl" || true
python3 - "$WORK/dropped.jsonl" <<'PY'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1]) if l.strip()][0]
assert not r["paste_landed"] and not r["clipboard_restored"], r
assert r["pasteboard_text"] == r["text"] != "", ("text not on the clipboard", r["pasteboard_text"])
assert "clipboard" in r["error"] and r["history_outcome"] == "paste_failed", r
assert r["inserted_text"] == "" and not r["window_visible"], r
print("paste not landed: text left on the clipboard")
PY

if [ "${LANGUAGES:-}" = skip ]; then
  echo "SKIPPED: languages (LANGUAGES=skip)"
  echo "e2e-mac: OK"
  exit 0
fi
WHISPER=${SHEPETAL_WHISPER_MODEL:-$PWD/bench/.cache/whisper/ggml-large-v3-turbo-q5_0.bin}
if [ ! -f "$WHISPER" ] && [ -z "${SHEPETAL_WHISPER_MODEL:-}" ]; then
  mkdir -p "$(dirname "$WHISPER")"
  curl -fL --progress-bar -o "$WHISPER.part" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin &&
    echo "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2  $WHISPER.part" | shasum -a 256 -c - &&
    mv "$WHISPER.part" "$WHISPER" ||
    { rm -f "$WHISPER.part"; echo "no whisper model at $WHISPER and the download failed (run once with the network on, or LANGUAGES=skip)" >&2; exit 1; }
fi
J=$FIX/j01
J_TEXT="明日の会議の資料を、金曜日までに送ってください。"
[ -f "$J.wav" ] || say -v Kyoko --data-format=LEI16@44100 -o "$J.wav" "$J_TEXT"
printf '%s\n' "$J_TEXT" > "$J.txt"
SHEPETAL_WHISPER_MODEL=$WHISPER E2E_LANGUAGES=en,ja "$BIN" --e2e "$J.wav" "$FIX/e01.wav" 2>>"$WORK/stderr.log" | tee "$WORK/languages.jsonl" || true
SHEPETAL_WHISPER_MODEL=$WHISPER E2E_LANGUAGES=en,ko "$BIN" --e2e "$J.wav" 2>>"$WORK/stderr.log" | tee "$WORK/outside.jsonl" || true
# The hint names the language in the system language (Locale.current): pinned, so "English" is checked on any Mac.
E2E_LANGUAGES=de,fr "$BIN" -AppleLocale en_US --e2e "$FIX/e02.wav" 2>>"$WORK/stderr.log" | tee "$WORK/wrong-language.jsonl" || true
python3 - "$WORK/languages.jsonl" "$WORK/wrong-language.jsonl" "$FIX" "$(basename "$WHISPER" .bin)" "$WORK/outside.jsonl" <<'PY'
import json, os, re, sys, unicodedata

def edits(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]

def chars(s):  # letters and digits only: punctuation and spaces differ between models
    return [c for c in s if unicodedata.category(c)[0] in "LN"]

def japanese(s):
    return [c for c in s if 0x3040 <= ord(c) <= 0x30FF or 0x4E00 <= ord(c) <= 0x9FFF]

def words(s):
    return re.sub(r"[^a-z0-9' ]+", " ", s.lower().replace("-", " ")).split()

langs, wrong, fix, whisper, outside = sys.argv[1:6]
rows = {os.path.basename(r["wav"]): r for r in map(json.loads, filter(str.strip, open(langs)))}
assert set(rows) == {"j01.wav", "e01.wav"}, ("clips missing from the languages run", sorted(rows))
for name, r in rows.items():
    assert r["error"] == "" and r["paste_landed"] and r["inserted_text"] == r["text"], (name, r)
    assert r["model"] == whisper, (name, "not the whisper model", r["model"])
    assert r["wrong_language_hint"] == "", (name, "whisper is told the language, so no hint", r["wrong_language_hint"])
    assert r["retranscribed_text"] == r["text"], (name, "re-transcribe", r["retranscribed_text"])
j, ref = rows["j01.wav"]["text"], open(os.path.join(fix, "j01.txt")).read()
cer = edits(chars(ref), chars(j)) / len(chars(ref))
assert len(japanese(j)) >= 0.8 * len(chars(j)) and cer <= 0.15, ("j01 not written in Japanese", cer, j)
e = rows["e01.wav"]["text"]
ref_e = words(open(os.path.join(fix, "e01.txt")).read())
wer = edits(ref_e, words(e)) / len(ref_e)
assert not japanese(e) and wer <= 0.08, ("e01 not written in English", wer, e)
assert (rows["j01.wav"]["language"], rows["e01.wav"]["language"]) == ("ja", "en"), "whisper was told another language"
(o,) = [json.loads(l) for l in open(outside) if l.strip()]
assert o["error"] == "" and o["model"] == whisper and o["language"] in ("en", "ko"), ("told a language not chosen", o["language"], o)
print(f"languages en,ja: j01 CER {cer:.1%} {j!r}, e01 WER {wer:.1%}, ready {rows['j01.wav']['ready_ms']}/{rows['e01.wav']['ready_ms']} ms")
print(f"languages en,ko: whisper told {o['language']!r} for j01, wrote {o['text']!r}")

(w,) = [json.loads(l) for l in open(wrong) if l.strip()]
assert w["error"] == "" and w["paste_landed"], ("the text is still inserted", w)
assert "English" in w["wrong_language_hint"], ("no wrong-language hint", w["wrong_language_hint"], w["text"])
print(f"languages de,fr: {w['model']} wrote {w['text']!r}, hint {w['wrong_language_hint']!r}")
print("e2e-mac: OK")
PY
