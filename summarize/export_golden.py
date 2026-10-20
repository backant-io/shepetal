"""Writes Tests/ShepetalSummaryTests/python_golden.json: what summarize.py (textrank-tfidf) says about each fixture.
The Swift port (Sources/ShepetalSummary) is tested against it. Rerun after changing summarize.py or the model:
  python3 summarize/export_golden.py
"""
import glob, json, os
import summarize as S

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Tests", "ShepetalSummaryTests", "python_golden.json")

gold = {}
for path in sorted(glob.glob(os.path.join(HERE, "fixtures", "*.txt"))):
    sents = S.parse(open(path).read())
    texts = [s for _, s in sents]
    rank = S.textrank(S.tfidf(texts))
    ov, pts = S.extractive(sents, S.tfidf)
    used = set(S.decisions(sents)) | {sents[a[0]][1] for a in S.action_items(sents)}
    ok = [i for i, s in enumerate(texts) if len(S.words(s)) >= 8 and not s.endswith("?")
          and not S.COMMIT.search(s) and not S.DECIDE.search(s) and s not in used]
    gold[os.path.basename(path)] = {
        "overview": ov,
        "overview_top3": [texts[i] for i in sorted(ok[:5], key=lambda i: -rank[i])[:3]],
        "key_points": pts,
        "decisions": S.decisions(sents),
        "actions": [list(a) for a in S.actions(sents)],
        "action_scores": S.action_scores(sents, S.load_model()),
    }
with open(OUT, "w") as f:
    json.dump(gold, f, indent=1, ensure_ascii=False)
    f.write("\n")
print("wrote", os.path.normpath(OUT))
