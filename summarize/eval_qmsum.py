"""Score the summarizer's summaries on real meetings: ROUGE against QMSum's general summaries.
Action items are scored on AMI's own labels and test split by ami_actions.py.

Data (text only, fetched once into .cache, which is gitignored):
  QMSum (MIT; 232 meetings = 137 AMI design meetings, 59 ICSI research meetings, 36 parliament committees):
    git clone -q --depth 1 --filter=blob:none --sparse https://github.com/Yale-LILY/QMSum.git .cache/qmsum
    git -C .cache/qmsum sparse-checkout set data/ALL/train data/ALL/val data/ALL/test
Usage: .venv/bin/python -I eval_qmsum.py [APPROACH]    (default textrank-tfidf)
"""
import glob, json, os, re, sys, time, resource

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # -I drops the script dir; add back only our own code dir, never a data dir
import summarize as S

QMSUM = os.path.join(HERE, ".cache", "qmsum", "data", "ALL")


def domain(mid):
    return "AMI" if re.match(r"(ES|IS|TS)\d", mid) else "ICSI" if re.match(r"B[a-z]{2}\d", mid) else "Committee"


def transcript(turns):
    """QMSum keeps corpus markup ({vocalsound}, {disfmarker}) and spaced punctuation ("okay ."); STT output has neither."""
    out = []
    for t in turns:
        s = re.sub(r"\s+([.,?!])", r"\1", re.sub(r"\{[^}]*\}", " ", t["content"]))
        s = re.sub(r"\s+", " ", s).strip()
        if s:
            out.append(f"{t['speaker']}: {s}")
    return "\n".join(out)


def main():
    approach = sys.argv[1] if len(sys.argv) > 1 else "textrank-tfidf"
    summarize = S.load(approach)
    rows = {}
    for path in sorted(glob.glob(os.path.join(QMSUM, "*", "*.json"))):
        mid = os.path.basename(path)[:-5]
        d = json.load(open(path))
        text = transcript(d["meeting_transcripts"])
        t = time.perf_counter()
        sents = S.parse(text)
        ov, pts = summarize(text, sents)
        md = S.render(ov, pts, S.decisions(sents), S.actions(sents))
        dt = time.perf_counter() - t
        ref = d["general_query_list"][0]["answer"]
        n = len(S.words(md))
        lead = " ".join(S.words(" ".join(s for _, s in sents))[:n])  # LEAD baseline: first n words of the meeting
        rows.setdefault(domain(mid), []).append((*S.rouge(ref, md), *S.rouge(ref, lead), dt, len(sents), n, len(S.words(ref))))
    print(f"{approach}: ROUGE F1 vs QMSum 'summarize the whole meeting' answers (full output / LEAD baseline at equal length)")
    print("| Corpus | Meetings | R-1 | R-2 | R-L | LEAD R-1 | LEAD R-2 | LEAD R-L | Sentences | Output / ref words | Latency mean / max |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for name, rs in sorted(rows.items()) + [("All", [r for rs in rows.values() for r in rs])]:
        m = [sum(r[i] for r in rs) / len(rs) for i in range(10)]
        print(f"| {name} | {len(rs)} | {m[0]:.3f} | {m[1]:.3f} | {m[2]:.3f} | {m[3]:.3f} | {m[4]:.3f} | {m[5]:.3f} | "
              f"{m[7]:.0f} | {m[8]:.0f} / {m[9]:.0f} | {m[6]*1000:.0f} / {max(r[6] for r in rs)*1000:.0f} ms |")
    print(f"Peak RSS: {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20):.0f} MB")


if __name__ == "__main__":
    main()
