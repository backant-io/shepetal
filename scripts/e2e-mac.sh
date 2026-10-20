#!/bin/bash
# End-to-end check of the Mac pipeline on speech made with `say`: capture resampler -> local STT ->
# cleanup -> audio store + history -> clipboard + Cmd+V into a text view the app owns.
# Asserts WER <= 8 %, text ready <= 700 ms after release, and an owner-only audio file per recording.
# A dictionary.txt in SHEPETAL_HOME replaces one word of e03; that clip is checked for the replacement and
# left out of the WER. SHEPETAL_HOME defaults to .cache/e2e/home.
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

"$BIN" --e2e "$FIX"/e*.wav ${ENGINE:+--engine "$ENGINE"} 2>"$WORK/stderr.log" | tee "$WORK/results.jsonl"

python3 - "$WORK/results.jsonl" "$FIX" "$DICT" <<'PY'
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
    assert r["inserted_text"] == r["text"], (name, "field holds something else", r["inserted_text"])
    assert r["paste_landed"] and r["clipboard_restored"], (name, "paste", r)
    if not os.environ.get("ENGINE"):
        assert r["ready_ms"] <= 700, (name, "slow", r["ready_ms"])
    p = r["audio_path"]
    st = os.stat(p)
    assert stat.S_IMODE(st.st_mode) == 0o600, (name, oct(st.st_mode))
    assert stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode) == 0o700, name
    assert not p.startswith(("/tmp", "/private/tmp")), p
    assert r["history_outcome"] == "inserted" and r["history_audio_path"] == p, (name, r["history_outcome"])
    data = open(p, "rb").read()
    fmt, ch, rate = struct.unpack("<HHI", data[20:28])
    assert (fmt, ch, rate) == (3, 1, 16000), (name, fmt, ch, rate)
    assert abs((len(data) - 44) / 4 / 16000 - r["audio_seconds"]) < 1e-3, name
    print(f"{name}: {e}/{len(ref)} word errors, ready {r['ready_ms']} ms, {r['audio_seconds']:.1f} s audio")
wer = errors / ref_words
print(f"model {rows[0]['model']}: WER {wer:.1%} over {len(rows) - len(replaced)} clips ({ref_words} words), "
      f"dictionary replacement in {', '.join(replaced)}")
assert wer <= 0.08, f"WER {wer:.1%} > 8%"
print("e2e-mac: OK")
PY
