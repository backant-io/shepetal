"""Scores cleanup-bench output against bench/cleanup/fixtures/dictation.jsonl.

python3 bench/cleanup/score.py [results/*.jsonl]   prints the docs/models.md Cleanup table
python3 bench/cleanup/score.py --context            the text-around-the-cursor table (F24, results/context/)
python3 bench/cleanup/score.py --self-test

Per run, two outputs are scored: `model` (the model alone on every fixture, after the rules) and `app` (the
app's path: rules, cue gate, model, word guard). Exact match is on the whole string, line breaks included.
Edit distance is characters changed per character of the expected text (CER).
"""
import json, os, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures", "dictation.jsonl")
CONTEXT = os.path.join(HERE, "fixtures", "context.jsonl")
LONG_WORDS = 24  # about 10 s of speech


def lev(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]


def score(fixtures, rows, key):
    exact, cer = 0, []
    for f in fixtures:
        out = rows[f["id"]].get(key, "").strip()
        exact += out == f["expected"]
        cer.append(lev(out, f["expected"]) / len(f["expected"]))
    return exact / len(fixtures), statistics.mean(cer)


def summarize(path, fixtures):
    lines = [json.loads(l) for l in open(path) if l.strip()]
    summary = next(l for l in lines if l.get("summary"))
    rows = {l["id"]: l for l in lines if "id" in l}
    missing = [f["id"] for f in fixtures if f["id"] not in rows]
    assert not missing, (path, "missing fixtures", missing)
    out = {"name": summary["model"], "load_ms": summary["load_ms"], "rss": summary["peak_rss_mb"],
           "footprint": summary["peak_footprint_mb"]}
    out["app_exact"], out["app_cer"] = score(fixtures, rows, "app")
    out["used"] = sum(rows[f["id"]]["used_model"] for f in fixtures)
    if "model" in rows[fixtures[0]["id"]]:
        out["model_exact"], out["model_cer"] = score(fixtures, rows, "model")
        out["model_ms"] = statistics.mean(rows[f["id"]]["model_ms"] for f in fixtures)
        out["max_ms"] = max(rows[f["id"]]["model_ms"] for f in fixtures)
        long = sorted(summary.get("long_ms", []))  # results/earlier-prompts predate the repeated runs
        assert len(long) in (0, 5 * sum(len(f["raw"].split()) >= LONG_WORDS for f in fixtures)), path
        out["long"] = f"{long[len(long) // 2]:.0f} / {long[-1]:.0f}" if long else "-"
    return out


def table(results):
    head = ("| Model | Exact, model on all | CER, model on all | Exact, app path | CER, app path | Model text used (app) "
            "| Mean ms per call | Max ms, any call | 10 s transcript ms, median / max | Load ms | Peak RSS MB "
            "| Peak footprint MB |\n|---|---|---|---|---|---|---|---|---|---|---|---|")
    lines = [head]
    for r in results:
        m = "model_exact" in r
        lines.append("| {} | {} | {} | {:.0%} | {:.1%} | {} | {} | {} | {} | {:.0f} | {} | {} |".format(
            r["name"], f"{r['model_exact']:.0%}" if m else "-", f"{r['model_cer']:.1%}" if m else "-",
            r["app_exact"], r["app_cer"], r["used"], f"{r['model_ms']:.0f}" if m else "-", f"{r['max_ms']:.0f}" if m else "-",
            r["long"] if m else "-", r["load_ms"], r["rss"], r["footprint"]))
    return "\n".join(lines)


def context_table(paths):
    """fixtures/context.jsonl on the app's path with the text around the cursor off (`app`) and on (`app_ctx`)."""
    fixtures = [json.loads(l) for l in open(CONTEXT) if l.strip()]
    lines = ["| Model | Exact, off | Exact, on | CER, off | CER, on | Model text used, on | Mean / max ms per model call, on |",
             "|---|---|---|---|---|---|---|"]
    for p in paths:
        rows = [json.loads(l) for l in open(p) if l.strip()]
        name = next(l for l in rows if l.get("summary"))["model"]
        rows = {l["id"]: l for l in rows if "id" in l}
        assert all(f["id"] in rows for f in fixtures), (p, "missing fixtures")
        off, on = score(fixtures, rows, "app"), score(fixtures, rows, "app_ctx")
        ms = [rows[f["id"]]["model_ctx_ms"] for f in fixtures if "model_ctx_ms" in rows[f["id"]]]
        lines.append("| {} | {:.0%} | {:.0%} | {:.1%} | {:.1%} | {} | {} |".format(
            name, off[0], on[0], off[1], on[1], sum(rows[f["id"]]["used_model_ctx"] for f in fixtures),
            f"{statistics.mean(ms):.0f} / {max(ms):.0f}" if ms else "-"))
    return "\n".join(lines)


def self_test():
    assert lev("kitten", "sitting") == 3 and lev("", "ab") == 2 and lev("a\nb", "a b") == 1
    fx = [{"id": "a", "raw": "x", "expected": "Hello."}, {"id": "b", "raw": "y", "expected": "1. A\n2. B"}]
    rows = {"a": {"app": "Hello."}, "b": {"app": "1. A 2. B"}}  # a lost line break is not an exact match
    exact, cer = score(fx, rows, "app")
    assert exact == 0.5 and abs(cer - (0 + 1 / 9) / 2) < 1e-9, (exact, cer)
    print("self-test ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit()
    if sys.argv[1:2] == ["--context"]:
        d = os.path.join(HERE, "results", "context")
        print(context_table(sys.argv[2:] or sorted(os.path.join(d, p) for p in os.listdir(d) if p.endswith(".jsonl"))))
        sys.exit()
    fixtures = [json.loads(l) for l in open(FIXTURES) if l.strip()]
    paths = sys.argv[1:] or sorted(os.path.join(HERE, "results", p) for p in os.listdir(os.path.join(HERE, "results"))
                                   if p.endswith(".jsonl"))
    print(table([summarize(p, fixtures) for p in paths]))
