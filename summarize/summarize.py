"""Local meeting summarizer + eval harness (no decoder-only LLMs).

Usage:
  .venv/bin/python summarize.py APPROACH [MODEL_ID]
APPROACH: textrank-tfidf | textrank-minilm | seq2seq (MODEL_ID = HF encoder-decoder id)
Summarizes fixtures/*.txt, writes out/APPROACH/*.md, prints ROUGE, latency, peak RSS.
"""
import os, re, sys, time, glob, resource, math
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("HF_HOME", os.path.join(HERE, ".cache", "hf"))

DAYS = r"(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
DUE = re.compile(rf"\b(?:by|on|before|for)?\s*((?:next\s+)?(?:{DAYS}|week)(?:\s+(?:morning|afternoon))?|today|tomorrow|tonight|end of (?:day|week)|the \d+(?:st|nd|rd|th))\b", re.I)
COMMIT = re.compile(r"\bI(?:'ll| will)\s+(.+)", re.I)
DECIDE = re.compile(r"\b(decision|decided|is postponed|we (?:move|keep|use|ship|offer|skip|roll back|don't store)|let's (?:ship|not|skip|use))\b", re.I)


def parse(text):
    """-> [(speaker, sentence)] in transcript order."""
    out = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        spk, body = line.split(":", 1)
        out += [(spk.strip(), s.strip()) for s in re.split(r"(?<=[.!?])\s+", body.strip()) if s.strip()]
    return out


def words(s):
    return re.findall(r"[a-z0-9']+", s.lower())


def similar(a, b, t=0.5):
    a, b = set(words(a)), set(words(b))
    return len(a & b) / max(1, min(len(a), len(b))) > t


def dedupe(items, key=lambda x: x):
    kept = []
    for it in items:
        if not any(similar(key(it), key(k)) for k in kept):
            kept.append(it)
    return kept


def decisions(sents):
    # ponytail: keyword rules tuned on English meeting phrasing; swap for a small classifier if recall is too low.
    out = []
    for _, s in sents:
        if s.endswith("?") or len(words(s)) < 6 or not DECIDE.search(s):
            continue
        s = re.split(r"(?i)decision(?: made)?\s*(?::|is)\s*", s)[-1]
        s = re.sub(r"^(?:so|okay|yes|and)[, ]+", "", s, flags=re.I)
        out.append(s[0].upper() + s[1:])
    return dedupe(out)


def actions(sents):
    """First-person commitments: owner = speaker, task = clause after I'll, due = date phrase."""
    out = []
    for spk, s in sents:
        m = COMMIT.search(s)
        if not m or s.endswith("?"):
            continue
        task = m.group(1).rstrip(".")
        d = DUE.search(task)
        due = d.group(1) if d else ""
        if d:
            task = re.sub(r"\s+,|\s+", lambda m: "," if "," in m.group() else " ", task[:d.start()] + task[d.end():]).strip(" ,")
        out.append((spk, task, due))
    return dedupe(out, key=lambda a: a[0] + " " + a[1])


def textrank(vecs, iters=50, d=0.85):
    import numpy as np
    v = vecs / (np.linalg.norm(vecs, axis=1, keepdims=True) + 1e-9)
    sim = np.clip(v @ v.T, 0, None)
    np.fill_diagonal(sim, 0)
    sim /= sim.sum(axis=1, keepdims=True) + 1e-9
    r = np.ones(len(v)) / len(v)
    for _ in range(iters):
        r = (1 - d) / len(v) + d * sim.T @ r
    return r


def tfidf(texts):
    import numpy as np
    docs = [Counter(words(t)) for t in texts]
    vocab = {w: i for i, w in enumerate(sorted({w for c in docs for w in c}))}
    df = Counter(w for c in docs for w in c)
    m = np.zeros((len(docs), len(vocab)))
    for i, c in enumerate(docs):
        for w, n in c.items():
            m[i, vocab[w]] = n * math.log(len(docs) / df[w])
    return m


def extractive(sents, embed, k=5):
    texts = [s for _, s in sents]
    rank = textrank(embed(texts))
    used = {s for s in decisions(sents)} | {a[1] for a in actions(sents)}
    ok = [i for i, s in enumerate(texts) if len(words(s)) >= 8 and not s.endswith("?")
          and not COMMIT.search(s) and not DECIDE.search(s) and s not in used]
    # ponytail: overview = best-ranked sentence in the opening (hosts state the purpose first).
    overview = texts[max(ok[:5], key=lambda i: rank[i])] if ok else ""
    top = sorted(dedupe(sorted((i for i in ok if texts[i] != overview), key=lambda i: -rank[i]),
                        key=lambda i: texts[i])[:k])
    return overview, [texts[i] for i in top]


def chunks(text, tok, limit):
    """Pack whole speaker turns into chunks of <= limit model tokens."""
    out, cur = [], ""
    for line in text.splitlines():
        if cur and len(tok(cur + "\n" + line).input_ids) > limit:
            out.append(cur)
            cur = line
        else:
            cur = (cur + "\n" + line).strip()
    return out + [cur] if cur else out


def rouge(ref, hyp):
    """ROUGE-1/2/L F1 on lowercased word tokens (no stemmer, so ~1-2 pts below rouge_score's stemmed numbers)."""
    r, h = words(re.sub(r"#+ .*", "", ref)), words(re.sub(r"#+ .*", "", hyp))
    def f(p, rc):
        return 0.0 if not p or not rc else 2 * p * rc / (p + rc)
    out = []
    for n in (1, 2):
        rn, hn = Counter(zip(*[r[i:] for i in range(n)])), Counter(zip(*[h[i:] for i in range(n)]))
        ov = sum((rn & hn).values())
        out.append(f(ov / max(1, sum(hn.values())), ov / max(1, sum(rn.values()))))
    prev = [0] * (len(h) + 1)
    for a in r:
        cur = [0]
        for j, b in enumerate(h):
            cur.append(prev[j] + 1 if a == b else max(prev[j + 1], cur[j]))
        prev = cur
    out.append(f(prev[-1] / max(1, len(h)), prev[-1] / max(1, len(r))))
    return out


def render(overview, points, decs, acts):
    md = f"## Overview\n{overview}\n\n## Key points\n" + "".join(f"- {p}\n" for p in points)
    md += "\n## Decisions\n" + "".join(f"- {d}\n" for d in decs)
    md += "\n## Action items\n" + "".join(f"- {o}: {t}" + (f" (due {d})" if d else "") + "\n" for o, t, d in acts)
    return md


def main():
    approach = sys.argv[1]
    model_id = sys.argv[2] if len(sys.argv) > 2 else ""
    t0 = time.perf_counter()
    if approach == "textrank-tfidf":
        summarize = lambda text, sents: extractive(sents, tfidf)
    elif approach == "textrank-minilm":
        import torch
        from transformers import AutoTokenizer, AutoModel
        src = model_id or os.path.join(HERE, ".cache", "minilm")  # sentence-transformers/all-MiniLM-L6-v2
        tok, enc = AutoTokenizer.from_pretrained(src), AutoModel.from_pretrained(src).eval()

        def embed(texts):  # mean pooling, same as sentence-transformers for this model
            with torch.no_grad():
                b = tok(texts, padding=True, truncation=True, max_length=128, return_tensors="pt")
                h = enc(**b).last_hidden_state
                m = b.attention_mask.unsqueeze(-1).float()
                return ((h * m).sum(1) / m.sum(1)).numpy()
        summarize = lambda text, sents: extractive(sents, embed)
    elif approach == "seq2seq":
        from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
        tok = AutoTokenizer.from_pretrained(model_id)
        model = AutoModelForSeq2SeqLM.from_pretrained(model_id).eval()
        prefix = "summarize: " if "t5" in model_id.lower() else ""
        limit = min(getattr(tok, "model_max_length", 512), 1024) - 16

        def summarize(text, sents):
            outs = []
            for c in chunks(text, tok, limit):
                ids = tok(prefix + c, return_tensors="pt", truncation=True, max_length=limit + 16)
                gen = model.generate(**ids, num_beams=4, max_new_tokens=120, no_repeat_ngram_size=3)
                outs += re.split(r"(?<=[.!?])\s+", tok.decode(gen[0], skip_special_tokens=True).strip())
            outs = dedupe([o for o in outs if o])
            return outs[0], outs[1:]
    else:
        sys.exit(f"unknown approach {approach}")
    load = time.perf_counter() - t0

    name = approach + ("-" + model_id.split("/")[-1] if model_id else "")
    os.makedirs(os.path.join(HERE, "out", name), exist_ok=True)
    rows = []
    for path in sorted(glob.glob(os.path.join(HERE, "fixtures", "*.txt"))):
        text = open(path).read()
        sents = parse(text)
        t = time.perf_counter()
        ov, pts = summarize(text, sents)
        md = render(ov, pts, decisions(sents), actions(sents))
        dt = time.perf_counter() - t
        open(os.path.join(HERE, "out", name, os.path.basename(path)[:-4] + ".md"), "w").write(md)
        ref = open(path[:-4] + ".ref.md").read()
        r = rouge(ref, md)
        rows.append((*r, dt))
    avg = [sum(r[i] for r in rows) / len(rows) for i in range(4)]
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20)  # bytes on macOS
    print(f"| {name} | {avg[0]:.3f} | {avg[1]:.3f} | {avg[2]:.3f} | {avg[3]*1000:.0f} ms | {load:.1f} s | {rss:.0f} MB |")


if __name__ == "__main__":
    main()
