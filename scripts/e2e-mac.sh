#!/bin/bash
# End-to-end check of the Mac pipeline on speech made with `say`: capture resampler -> local STT ->
# cleanup (rules, then the local model on self-corrections and lists) -> audio store + history ->
# pasteboard + Cmd+V into a text view the app owns.
# The test shows no window, never takes focus, and uses a private pasteboard, never the user's clipboard.
# Asserts WER <= 8 %, text ready <= 700 ms after release, and an owner-only audio file per recording.
# Run it offline to prove transcription makes no network call:
#   sandbox-exec -p '(version 1)(allow default)(deny network*)' scripts/e2e-mac.sh
# ENGINE=fallback runs the whisper.cpp fallback instead of Parakeet (the latency bar applies to the
# default model only).
# The c* clips need the local cleanup model: SHEPETAL_CLEANUP_MODEL (default: Qwen3.5 2B in bench/.cache/cleanup,
# downloaded there on the first run, about 1.3 GB, so run once with the network on). CLEANUP=rules skips them
# and says so.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=${SHEPETAL_BIN:-.build/release/shepetal}
[ -x "$BIN" ] || swift build -c release
WORK=$PWD/.cache/e2e
FIX=$WORK/fixtures
export SHEPETAL_HOME=${SHEPETAL_HOME:-$WORK/home}
mkdir -p "$FIX"
rm -f "$FIX"/c*.gone

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
fi

"$BIN" --e2e "${CLIPS[@]}" ${ENGINE:+--engine "$ENGINE"} 2>"$WORK/stderr.log" | tee "$WORK/results.jsonl"

python3 - "$WORK/results.jsonl" "$FIX" <<'PY'
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

results, fix = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(results) if l.strip()]
assert rows and all("wav" in r for r in rows), f"no results: {rows}"
errors = ref_words = 0
for r in rows:
    name = os.path.basename(r["wav"])
    assert r["error"] == "", (name, r["error"])
    ref = words(open(os.path.join(fix, name[:-4] + ".txt")).read())
    e = edits(ref, words(r["inserted_text"]))
    errors += e; ref_words += len(ref)
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
    data = open(p, "rb").read()
    fmt, ch, rate = struct.unpack("<HHI", data[20:28])
    assert (fmt, ch, rate) == (3, 1, 16000), (name, fmt, ch, rate)
    assert abs((len(data) - 44) / 4 / 16000 - r["audio_seconds"]) < 1e-3, name
    gone = os.path.join(fix, name[:-4] + ".gone")
    if os.path.exists(gone):  # a cleanup clip: the model rewrote it and the taken-back words are gone
        assert r["cleanup_model"], (name, "cleanup model not used", r["cleanup_status"], r["text"])
        left = set(open(gone).read().split()) & set(words(r["inserted_text"]))
        assert not left, (name, "taken-back words left", left, r["inserted_text"])
    print(f"{name}: {e}/{len(ref)} word errors, ready {r['ready_ms']} ms, {r['audio_seconds']:.1f} s audio, "
          f"cleanup {r.get('cleanup_model') or 'rules'}")
wer = errors / ref_words
print(f"model {rows[0]['model']}: WER {wer:.1%} over {len(rows)} clips ({ref_words} words)")
assert wer <= 0.08, f"WER {wer:.1%} > 8%"
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
