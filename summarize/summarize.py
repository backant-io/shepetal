"""Local meeting summarizer + eval harness (no decoder-only LLMs).

Usage:
  .venv/bin/python summarize.py APPROACH [MODEL_ID]
APPROACH: textrank-tfidf | textrank-minilm | seq2seq (MODEL_ID = HF encoder-decoder id)
Summarizes fixtures/*.txt, writes out/APPROACH/*.md, prints ROUGE, latency, peak RSS.
"""
import os, re, sys, time, glob, json, resource, math
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("HF_HOME", os.path.join(HERE, ".cache", "hf"))

DAYS = r"(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
DUE = re.compile(rf"\b(?:by|on|before|for)?\s*((?:next\s+)?(?:{DAYS}|week)(?:\s+(?:morning|afternoon))?|today|tomorrow|tonight|end of (?:day|week)|the \d+(?:st|nd|rd|th))\b", re.I)
COMMIT = re.compile(r"\bI(?:'ll| will)\s+(.+)", re.I)
DECIDE = re.compile(r"\b(decision|decided|is postponed|we (?:move|keep|use|ship|offer|skip|roll back|don't store)|let's (?:ship|not|skip|use))\b", re.I)


# "Maya: ...", "Speaker 1: ...", "张伟: ...": starts with a letter, at most 4 words, no sentence punctuation, and a
# space after the colon, so "at 10:30" or "https://..." is never a label.
LABEL = re.compile(r"^\s*([^\W\d_][^:.!?]{0,39}?)\s*:(?:\s|$)")


def parse(text):
    """-> [(speaker, sentence)] in transcript order. Lines without a label keep an unknown speaker ("").
    Labels count only when at least half the lines have one: in an undiarized transcript (the iPhone mic path)
    a stray "Note: I will..." is text, not a speaker."""
    lines = [l for l in text.splitlines() if l.strip()]
    found = [LABEL.match(l) for l in lines]
    found = [m if m and len(m.group(1).split()) <= 4 else None for m in found]
    diarized = 2 * sum(m is not None for m in found) >= len(lines)
    out = []
    for line, m in zip(lines, found):
        spk, body = (m.group(1), line[m.end():]) if m and diarized else ("", line)
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
        if not words(s):  # "we reached our decision:" with the content in a later sentence
            continue
        out.append(s[0].upper() + s[1:])
    return dedupe(out)


MODEL = os.path.join(HERE, "actions_model.json")  # trained by ami_actions.py on the AMI train split
_model = {}
SELF = re.compile(r"\b(?:i'll|i will|i'm going to|i'm gonna|i can|let me|i have to|i need to|i should)\b")
YOU = re.compile(r"\b(?:you|you'll|you're|your|you've|you'd)\b")
ME = re.compile(r"\b(?:i|i'll|i'm|i've|i'd|me|my)\b")
DELEGATE = re.compile(r"\s*(?:\w+\s+)?(?:ask|want|like|need|tell|get)\b")
INTRO = re.compile(r"\b(?:I'm|I am|my name is|my name's|[Tt]his is)\s+([A-Z][a-z]+)\b(?!')")  # "This is Kate's laptop" is no intro
FILLER = re.compile(r"^(?:(?:um|uh|so|and|okay|ok|well|yeah|right|but|then|also|now|alright)\b[,.]?\s*)+", re.I)


def action_features(sents):
    """Binary features per sentence: words, word pairs, the words around it, position, length and the old rules."""
    n = len(sents)
    chair = Counter(s for s, _ in sents).most_common(1)[0][0] if sents else None  # the person who talks most runs the meeting
    W = [words(t) for _, t in sents]
    out = []
    for i, (spk, t) in enumerate(sents):
        f = {"u:" + x for x in W[i]} | {"b:" + a + "_" + b for a, b in zip(W[i], W[i][1:])}
        f |= {"p:" + x for x in (W[i - 1] if i else [])} | {"n:" + x for x in (W[i + 1] if i + 1 < n else [])}
        f |= {f"pos{10 * i // n}", f"len{min(5, len(W[i]) // 4)}"}
        f |= {k for k, on in (("chair", spk == chair), ("q", t.endswith("?")), ("due", DUE.search(t)), ("commit", COMMIT.search(t))) if on}
        out.append(f)
    return out


def load_model(path=MODEL):
    if not _model:
        with open(path) as f:  # no fallback: a missing model must fail loudly, not quietly return the old 4% rule
            _model.update(json.load(f))
    return _model


def action_scores(sents, model):
    """-> P(sentence is an action item) from the linear model: sigmoid(bias + sum of the weights of its features)."""
    w, b = model["weights"], model["bias"]
    return [1 / (1 + math.exp(-(b + sum(w.get(x, 0.0) for x in f)))) for f in action_features(sents)]


def tokens(s):
    """words() with the case kept: names are matched as written."""
    return re.findall(r"[\w']+", s)  # Unicode letters too: "Олена" and "张伟" are names


def aliases(sents):
    """-> {spoken phrase: speaker label}: the label, its words, its initials, and names people introduce themselves with.
    owner() matches them as written: a name only when capitalized, initials only in capitals. With calendar names,
    "you will", "it is" and "look at" must not hand the task to Will, Ian Smith or Amy Thompson."""
    labels = sorted({s for s, _ in sents if s})
    out = {}
    for lab in labels:
        toks = [w[:1].upper() + w[1:] for w in tokens(lab)]  # a lowercase calendar name "will" must not match "will"
        if not toks:  # a label with no letters ("—") would become the empty phrase, which matches every sentence
            continue
        others = {w for l in labels if l != lab for w in words(l)}
        out[" ".join(toks)] = lab
        out.update({w: lab for w in toks if len(w) >= 3 and w.lower() not in others and not w.isdigit()})  # "Speaker 1" gives nothing
        if len(toks) > 1:
            # "Industrial Designer" is called "ID". ponytail: an acronym equal to someone's initials ("OK" for Olga Kim,
            # "PM" as a time for Paul Miller) still names them; drop initials for name labels if that shows up.
            out["".join(w[0] for w in toks)] = lab
    for spk, t in sents:
        for m in INTRO.finditer(t):
            if spk and not re.fullmatch(DAYS, m.group(1), re.I):  # "This is Friday" is a date, not a name
                out.setdefault(m.group(1), spk)
    return out


def owner(sents, i, al):
    """Who does it: a named participant, else "I" -> the speaker, "you" -> whoever answers, else the addressee."""
    spk, t = sents[i]
    c = " ".join(tokens(t))
    w = c.lower()  # same length as c, so match positions compare
    named = [(m.start(), lab) for k, lab in al.items() if lab != spk for m in [re.search(rf"\b{re.escape(k)}\b", c)] if m]
    me = SELF.search(w)
    if me and not (named and (min(named)[0] < me.start() or DELEGATE.match(w, me.end()))):
        return spk  # "I'll send the list to Daniel" is mine; "I'll ask Daniel to send it" is his
    if named:
        return min(named)[1]
    if YOU.search(w) or not ME.search(w):
        # ponytail: addressee = next other speaker within 3 sentences (they usually acknowledge), else the previous one.
        for j in [*range(i + 1, min(len(sents), i + 4)), *range(i - 1, max(-1, i - 4), -1)]:
            if sents[j][0] and sents[j][0] != spk:
                return sents[j][0]
    return spk


def action_items(sents, model=None):
    """-> [(sentence index, owner, task, due)]: classifier hits plus first-person commitments with a date."""
    model = model or load_model()
    p, al, out = action_scores(sents, model), aliases(sents), []
    for i, (spk, s) in enumerate(sents):
        m = COMMIT.search(s)
        if s.endswith("?") or not (p[i] >= model["threshold"] or (m and DUE.search(s))):
            continue
        who = owner(sents, i, al)
        task = (m.group(1) if m and who == spk else FILLER.sub("", s)).rstrip(".,")
        if not words(task):  # "Okay, so." scored high from its neighbours; there is no task to show
            continue
        ds = list(DUE.finditer(task))  # "follow up today and send it by Friday": the deadline is the "by" date
        d = next((x for x in ds if x.group().strip().lower().startswith(("by ", "before "))), ds[0] if ds else None)
        due = d.group(1) if d else ""
        if d:
            task = re.sub(r"\s+,|\s+", lambda m: "," if "," in m.group() else " ", task[:d.start()] + task[d.end():]).strip(" ,")
        # The same task said twice by or to the same person: keep the later mention (the recap), drop the earlier one.
        out = [k for k in out if not (k[1] == who and similar(k[2], task))] + [(i, who, task, due)]
    return out


def actions(sents, model=None):
    """-> [(owner, task, due)] for the Action items section."""
    return [a[1:] for a in action_items(sents, model)]


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
    if not sents:  # empty or silent recording
        return "", []
    texts = [s for _, s in sents]
    rank = textrank(embed(texts))
    used = set(decisions(sents)) | {sents[a[0]][1] for a in action_items(sents)}
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
    md += "\n## Action items\n" + "".join(f"- {o + ': ' if o else ''}{t}" + (f" (due {d})" if d else "") + "\n" for o, t, d in acts)
    return md


def load(approach, model_id=""):
    """-> summarize(text, sents) -> (overview, key points)."""
    if approach == "textrank-tfidf":  # numpy only: no torch, no model file
        return lambda text, sents: extractive(sents, tfidf)
    if approach == "textrank-minilm":
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
        return lambda text, sents: extractive(sents, embed)
    if approach == "seq2seq":
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
        return summarize
    sys.exit(f"unknown approach {approach}")


def main():
    approach = sys.argv[1]
    model_id = sys.argv[2] if len(sys.argv) > 2 else ""
    t0 = time.perf_counter()
    summarize = load(approach, model_id)
    load_s = time.perf_counter() - t0

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
    print(f"| {name} | {avg[0]:.3f} | {avg[1]:.3f} | {avg[2]:.3f} | {avg[3]*1000:.0f} ms | {load_s:.1f} s | {rss:.0f} MB |")


if __name__ == "__main__":
    main()
