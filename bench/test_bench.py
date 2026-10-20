"""Tests for bench.py. These numbers pick shepetal's default model, so a wrong WER, timing or RSS must fail here.

run: uv run --no-project --python 3.12 --with jiwer python bench/test_bench.py -v   (no models needed)
"""
import json, os, re, time, unittest
import bench

ROOT = os.path.dirname(bench.HERE)

def read(*p):  # path relative to the repo root
    with open(os.path.join(ROOT, *p)) as f: return f.read()


class Norm(unittest.TestCase):
    def test_each_rule(self):  # one case per rule, so dropping any rule changes some model's WER silently
        for raw, want in [
            ("with a 2% discount", "with a 2 percent discount"),
            ("cost $5", "cost dollars 5"),
            ("4,250 dollars", "4250 dollars"),
            ("on the 15th", "on the 15"),
            ("at 3pm", "at 3 pm"),
            ("at 3 p.m.", "at 3 pm"),  # the fixture reference says "3 PM"
            ("two-day fix", "2 day fix"),
            ("Ship it. No, wait!", "ship it no wait"),
            ("don't", "don't"),
            ("zero one ten", "0 1 10"),
        ]:
            self.assertEqual(bench.norm(raw), want, raw)


def row(f, ref, hyp, sec, lat):
    return dict(f=f, sec=sec, lat=lat, ref=ref, hyp=hyp)


class Score(unittest.TestCase):
    rows = [row("d01.wav", "a b c d", "a x c d", 4.0, 0.1),      # 1 substitution
            row("d02.wav", "e f g h", "e f g h", 6.0, 0.3),      # exact
            row("meeting.wav", "m n", "m", 10.0, 1.0)]           # 1 deletion

    def test_wer_compares_hypothesis_to_reference(self):
        s = bench.score(self.rows)
        self.assertEqual(s["wer_dictation"], 12.5)  # 1 error / 8 reference words, dictation clips pooled
        self.assertEqual(s["wer_meeting"], 50.0)

    def test_latency_and_rtf(self):
        s = bench.score(self.rows)
        self.assertEqual(s["latency_dictation_ms_mean"], 200)  # meeting is not part of the dictation mean
        self.assertEqual(s["latency_meeting_ms"], 1000)
        self.assertEqual(s["rtf"], 0.07)  # 1.4 s of decoding over 20 s of audio


class Timing(unittest.TestCase):
    def test_sherpa_times_the_decode(self):
        class Stream:
            result = type("R", (), {"text": "hi"})
            def accept_waveform(self, sr, a): pass
        class Recognizer:
            def create_stream(self): return Stream()
            def decode_stream(self, s): time.sleep(0.05)
        text, lat = bench.timed(Recognizer(), [0.0], 16000)
        self.assertEqual(text, "hi")
        self.assertGreaterEqual(lat, 0.05)

    def test_whisper_cpp_excludes_model_load(self):
        err = "whisper_print_timings:     load time =   120.50 ms\nwhisper_print_timings:    total time =   400.50 ms\n"
        self.assertAlmostEqual(bench.wcpp_lat(err), 0.28)


class Rss(unittest.TestCase):
    def test_units_per_platform(self):  # 310 MB peak, as each kernel reports ru_maxrss
        self.assertEqual(bench.rss_mb(325320704, "darwin"), 310)  # bytes
        self.assertEqual(bench.rss_mb(317440, "linux"), 310)      # kilobytes


class DocsMatchResults(unittest.TestCase):
    """Every measured row in docs/models.md must be the latest committed run of its engine."""

    def test_measured_table(self):
        last = {}
        for line in read("bench", "results", "summary.jsonl").splitlines():
            d = json.loads(line); last[d["engine"]] = d
        seen = set()
        for line in read("docs", "models.md").splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) != 9 or cells[-1] != "measured": continue
            m = re.search(r"`([^`]+)`", cells[0]); self.assertIsNotNone(m, "measured row without its engine id: " + cells[0])
            e = m.group(1); s = last[e]; seen.add(e)
            rows = json.loads(read("bench", "results", e + ".json"))
            self.assertEqual({k: s[k] for k in bench.score(rows)}, bench.score(rows), e + ": summary.jsonl vs per-file json")
            for cell, want in [(cells[2], s["peak_rss_mb"]), (cells[3], s["wer_dictation"]), (cells[4], s["wer_meeting"]),
                               (cells[5], s["latency_dictation_ms_mean"]), (cells[6], s["latency_meeting_ms"] / 1000),
                               (cells[7], s["rtf"])]:
                num = re.search(r"\d[\d,]*(\.\d+)?", cell)
                tol = 0.5 * 10 ** -(len(num.group(1) or ".") - 1)  # half the last digit shown
                self.assertLessEqual(abs(float(num.group().replace(",", "")) - want), tol + 1e-9, f"{e}: {cell} vs {want}")
        self.assertEqual(seen, {f[:-5] for f in os.listdir(os.path.join(bench.HERE, "results")) if f.endswith(".json")})

    def test_longest_clip_claim(self):  # the goal's bar is time to text for a ~10 s utterance
        rows = json.loads(read("bench", "results", "fluid-parakeet-v3.json"))
        d = max((r for r in rows if r["f"].startswith("d")), key=lambda r: r["sec"])
        m = re.search(r"(\d+) ms on the longest clip \((d\d+)", read("docs", "models.md"))
        self.assertIsNotNone(m, "docs/models.md lost the 'N ms on the longest clip (dNN' claim")
        self.assertEqual((int(m.group(1)), m.group(2)), (round(d["lat"] * 1000), d["f"][:-4]))


if __name__ == "__main__":
    unittest.main()
