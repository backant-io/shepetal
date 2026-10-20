#!/bin/bash
# End-to-end check of meeting transcription without capture or UI: `say` makes a two-voice meeting (Samantha is
# "Me" on the mic channel, Daniel is "Others" on the system-audio channel, each silent while the other talks),
# and `shepetal --e2e-meeting` writes both channels into a meeting folder as the recorder does (live passes every
# 30 s, then the final pass), transcribes them with the app's speech model, stores them and summarizes them.
# Asserts: segments in time order with the right speaker at the right time, at least 80% of each speaker's words,
# live segments stored before the end, the meeting read back from the store and found by search, owner-only
# audio, and a summary with at least one action item. The app runs with the network denied (sandbox-exec), so
# transcription and summary make no network call.
# BLEED=0.05 also mixes the other side into the mic channel at that gain (about -26 dB), as a MacBook's speakers
# do without headphones: the same checks must pass, so none of that echo may come out as Me.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${SHEPETAL_BIN:-}" ]; then
  swift build -j 4 >&2
  SHEPETAL_BIN=$(swift build -j 4 --show-bin-path)/shepetal
fi
WORK=$PWD/.cache/e2e-meeting
FIX=$WORK/fixtures
export SHEPETAL_HOME=${SHEPETAL_HOME:-$WORK/home}
mkdir -p "$FIX"

# speaker|text, in the order spoken
cat > "$FIX/script.txt" <<'LINES'
Me|Thanks for joining, everyone. Today we need to plan the launch of the new mobile app.
Others|Sure. The beta build is ready, but the login screen still crashes on older phones.
Me|That sounds serious. How many of our testers are affected by the crash?
Others|Only a few of them, and I think the fix is small.
Me|Okay. We decided to delay the launch by one week so that we can fix the crash first.
Others|That works for me. I will fix the login crash by Wednesday and send you the new build.
Me|Great. I will send the updated launch plan to the marketing team by Friday.
Others|Could you also book the meeting room for the launch party next month?
Me|Yes, I will book the room tomorrow morning and share the details with the whole team.
Others|Perfect. Then we are done for today. Thanks, everyone.
LINES

i=0
while IFS='|' read -r who text; do
  voice=Samantha; [ "$who" = Others ] && voice=Daniel
  [ -f "$FIX/line$i.wav" ] || say -v "$voice" --data-format=LEI16@16000 -o "$FIX/line$i.wav" "$text"
  i=$((i + 1))
done < "$FIX/script.txt"

# Lay the lines end to end: each channel holds its speaker's lines and silence while the other speaks.
BLEED=${BLEED:-0} python3 - "$FIX" <<'PY'
import array, json, os, sys, wave
fix = sys.argv[1]
lines = [l.rstrip("\n").split("|", 1) for l in open(os.path.join(fix, "script.txt")) if l.strip()]
rate, gap = 16000, int(0.8 * 16000)
tracks = {"Me": bytearray(), "Others": bytearray()}
ref, t = [], gap
for i, (who, text) in enumerate(lines):
    with wave.open(os.path.join(fix, f"line{i}.wav")) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (rate, 1, 2)
        pcm = w.readframes(w.getnframes())
    n = len(pcm) // 2
    for k, tr in tracks.items():
        tr += bytes(2 * (t - len(tr) // 2))  # silence up to this line
        tr += pcm if k == who else bytes(len(pcm))
    ref.append({"speaker": who, "start": t / rate, "end": (t + n) / rate, "text": text})
    t += n + gap
bleed = float(os.environ["BLEED"])
if bleed:
    me, ot = array.array("h", tracks["Me"]), array.array("h", tracks["Others"])
    tracks["Me"] = bytearray(array.array("h", (max(-32768, min(32767, m + round(bleed * o))) for m, o in zip(me, ot))).tobytes())
for k, tr in tracks.items():
    tr += bytes(2 * (t - len(tr) // 2))
    with wave.open(os.path.join(fix, f"{k.lower()}.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(tr))
json.dump(ref, open(os.path.join(fix, "ref.json"), "w"), indent=1)
print(f"meeting: {len(ref)} lines, {t / rate:.1f} s, bleed {bleed}", file=sys.stderr)
PY

sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  "$SHEPETAL_BIN" --e2e-meeting "$FIX/me.wav" "$FIX/others.wav" 2>"$WORK/stderr.log" | tee "$WORK/result.json"

python3 - "$WORK/result.json" "$FIX/ref.json" <<'PY'
import json, os, re, stat, sys
from collections import Counter

def words(s):
    return re.findall(r"[a-z0-9']+", s.lower().replace("-", " "))

def recall(ref, hyp):
    """Share of the reference words found in the transcript (each heard word counts once)."""
    r, h = Counter(ref), Counter(hyp)
    return sum(min(c, h[w]) for w, c in r.items()) / max(1, sum(r.values()))

assert recall(["a", "b", "b", "c"], ["b", "a", "x"]) == 0.5  # self-check of the metric

r = json.load(open(sys.argv[1]))
ref = json.load(open(sys.argv[2]))
assert r["error"] == "", r["error"]
segs = r["segments"]
assert segs, "no segments"
starts = [s["start"] for s in segs]
assert starts == sorted(starts), "segments are not in time order"
assert {s["speaker"] for s in segs} == {"Me", "Others"}, "both speakers must appear"
total = max(r["audio_seconds"])
for s in segs:
    assert 0 <= s["start"] < s["end"] <= total + 0.01, ("time outside the meeting", s)
    # Each segment sits on a line of its own speaker: speaker and time are both right.
    own = [l for l in ref if l["speaker"] == s["speaker"] and l["start"] - 0.5 < s["end"] and s["start"] < l["end"] + 0.5]
    assert own, ("segment is not on a line of its speaker", s)
for l in ref:
    assert any(s["speaker"] == l["speaker"] and s["start"] <= l["start"] + 0.5 and s["end"] >= l["end"] - 0.5 for s in segs), \
        ("line not covered by a segment of its speaker", l)
for who in ("Me", "Others"):
    rw = [w for l in ref if l["speaker"] == who for w in words(l["text"])]
    hw = [w for s in segs if s["speaker"] == who for w in words(s["text"])]
    rc = recall(rw, hw)
    print(f"{who}: {rc:.0%} of {len(rw)} reference words")
    assert rc >= 0.8, f"{who}: only {rc:.0%} of the reference words"

assert r["live_segments"] >= 1, "no segment while the meeting was running"
assert len(segs) > r["live_segments"], "the final pass added nothing after the last live pass"
assert r["stored_before_finish"] == r["live_segments"], ("live segments not stored", r["stored_before_finish"])
assert r["stored_segments"] == segs and r["stored_summary"] == r["summary"], "store differs from the result"
assert r["stored_app"] == "E2E Meeting" and r["stored_ended"] and r["listed"], "stored meeting"
assert r["search_query"] and r["search_hit"], ("search did not find the meeting", r["search_query"])

for p, m in zip(r["stored_audio"], r["audio_modes"]):
    assert os.path.exists(p) and m == "600", ("meeting audio", p, m)
    assert not os.path.realpath(p).startswith(("/tmp", "/private/tmp")), p
    assert stat.S_IMODE(os.stat(p).st_mode) == 0o600, p
assert r["dir_mode"] == "700" and r["db_mode"] == "600", (r["dir_mode"], r["db_mode"])
assert not r["scratch_left"], "the per-utterance scratch file was left behind"

acts = r["summary"]["action_items"]
assert acts, ("no action item in the summary", r["summary"])
for a in acts:
    print(f"action: {a['owner'] or '?'}: {a['task']}" + (f" ({a['due']})" if a["due"] else ""))
print(f"{len(segs)} segments ({r['live_segments']} live), finish {r['finish_ms']} ms, {total:.1f} s meeting")
print("e2e-meeting: OK")
PY
