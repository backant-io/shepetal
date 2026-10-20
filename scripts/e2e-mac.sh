#!/bin/bash
# End-to-end check of the Mac pipeline on speech made with `say`: capture resampler -> local STT ->
# cleanup -> audio store + history -> pasteboard + Cmd+V into a text view the app owns.
# The test shows no window, never takes focus, and uses a private pasteboard, never the user's clipboard.
# Asserts WER <= 8 %, text ready <= 700 ms after release, an owner-only audio file per recording, and
# that history kept the app, bundle id and page URL given for each dictation. The page-URL lookup must
# return at once and do its work off the main thread. Each clip is then re-transcribed from its kept WAV,
# as History's re-transcribe does, and must give the same text and the engine's model name on the same row.
# A dictionary.txt in SHEPETAL_HOME replaces one word of e03; that clip is checked for the replacement and
# left out of the WER. SHEPETAL_HOME defaults to .cache/e2e/home.
# A separate run on 2 s of digital silence must paste nothing and keep the audio as "no_speech".
# e01-quiet is e01 at -40 dB (loudest 100 ms about -52 dBFS): it must still be inserted word for word,
# so a speech floor set too high fails here.
# Run it offline to prove transcription makes no network call:
#   sandbox-exec -p '(version 1)(allow default)(deny network*)' scripts/e2e-mac.sh
# ENGINE=fallback runs the whisper.cpp fallback instead of Parakeet (the latency bar applies to the
# default model only).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=${SHEPETAL_BIN:-.build/release/shepetal}
[ -x "$BIN" ] || swift build -c release
WORK=$PWD/.cache/e2e
FIX=$WORK/fixtures
export SHEPETAL_HOME=${SHEPETAL_HOME:-$WORK/home}
mkdir -p "$FIX" "$SHEPETAL_HOME"
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

# A clip with an error exits 1; the checks below name it.
"$BIN" --e2e "$FIX"/e*.wav ${ENGINE:+--engine "$ENGINE"} 2>"$WORK/stderr.log" | tee "$WORK/results.jsonl" || true

# Silence exits 1 by design ("No speech heard"); the checks below read its JSON line.
python3 -c 'import sys, wave; w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(64000)); w.close()' "$FIX/silence.wav"
"$BIN" --e2e "$FIX/silence.wav" ${ENGINE:+--engine "$ENGINE"} 2>>"$WORK/stderr.log" | tee "$WORK/silence.jsonl" || true

python3 - "$WORK/results.jsonl" "$FIX" "$DICT" "$WORK/silence.jsonl" <<'PY'
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
want = sorted(f for f in os.listdir(fix) if re.fullmatch(r"e\d\d(-quiet)?\.wav", f))
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
    if not os.environ.get("ENGINE"):
        assert r["ready_ms"] <= 700, (name, "slow", r["ready_ms"])
    p = r["audio_path"]
    st = os.stat(p)
    assert stat.S_IMODE(st.st_mode) == 0o600, (name, oct(st.st_mode))
    assert stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode) == 0o700, name
    assert not p.startswith(("/tmp", "/private/tmp")), p
    assert r["history_outcome"] == "inserted" and r["history_audio_path"] == p, (name, r["history_outcome"])
    app = (r["history_app"], r["history_bundle_id"], r["history_url"])
    assert app == ("E2E Browser", "com.apple.Safari", "https://example.com/e2e/page"), (name, "app at dictation start", app)
    assert r["app_resolve_ms"] < 100, (name, "page-URL lookup held the main thread", r["app_resolve_ms"])
    assert r["retranscribed_text"] == r["text"] and r["retranscribed_row_kept"], (name, "re-transcribe", r)
    assert r["retranscribed_model"] == r["model"], (name, "re-transcribe model", r["retranscribed_model"])
    data = open(p, "rb").read()
    fmt, ch, rate = struct.unpack("<HHI", data[20:28])
    assert (fmt, ch, rate) == (3, 1, 16000), (name, fmt, ch, rate)
    assert abs((len(data) - 44) / 4 / 16000 - r["audio_seconds"]) < 1e-3, name
    print(f"{name}: {e}/{len(ref)} word errors, ready {r['ready_ms']} ms, {r['audio_seconds']:.1f} s audio")
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
print("e2e-mac: OK")
PY
