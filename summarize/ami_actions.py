"""AMI action items: load labels, train the action-item classifier, score it on the AMI test split.

Data: AMI manual annotations 1.6.2 (CC BY 4.0), text only, into .cache (gitignored):
  mkdir -p .cache/ami && curl -sSLo .cache/ami/m.zip https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip
  unzip -q -o .cache/ami/m.zip 'abstractive/*' 'extractive/*' 'dialogueActs/*' 'words/*' 'corpusResources/*' -d .cache/ami
Labels: a dialogue act is an action item when a summlink ties it to a sentence in the <actions> list of the
meeting's abstractive summary. The owner is the role named in that sentence's subject.
Split: corpusResources/meetings.xml seen_type (training 98 / development 20 / unseen = test 20 scenario meetings).
Usage: .venv/bin/python -I ami_actions.py train | eval [dev|test]
"""
import html, json, math, os, re, resource, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # -I drops the script dir; add back only our own code dir, never a data dir
import summarize as S

AMI = os.path.join(HERE, ".cache", "ami")
ROLE = {"PM": "Project Manager", "ID": "Industrial Designer", "UI": "User Interface", "ME": "Marketing"}
OWNER = [(r"project manager|\bpm\b", "Project Manager"), (r"industrial|\bid\b", "Industrial Designer"),
         (r"interface|\bui\b", "User Interface"), (r"marketing", "Marketing")]


def read(path):
    with open(path, encoding="latin-1") as f:
        return f.read()


def owners(sentence):
    """Roles named in the subject ("The ID and UI will ...") only; "The team will decide how the interface ..." has none."""
    subj = re.split(r"\b(?:will|were|was|are|is|has|have|should|must|needs?)\b", sentence.lower())[0]
    return {role for key, role in OWNER if re.search(key, subj)}


def splits():
    """-> {meeting id: 'train' | 'dev' | 'test'} for the scenario meetings, from the corpus's own metadata."""
    name = {"training": "train", "development": "dev"}
    out = {}
    for m in re.findall(r"<meeting [^>]*>", read(os.path.join(AMI, "corpusResources", "meetings.xml"))):
        mid, typ = re.search(r'observation="([^"]+)"', m).group(1), re.search(r'type="([^"]+)"', m).group(1)
        seen = re.search(r'seen_type="([^"]+)"', m)
        if typ == "scenario":
            out[mid] = name.get(seen.group(1), "test") if seen else "test"
    return out


def roles(mid):
    meet = re.search(rf'<meeting [^>]*observation="{mid}".*?</meeting>', read(os.path.join(AMI, "corpusResources", "meetings.xml")), re.S)
    return dict(re.findall(r'nxt_agent="([A-Z])"[^>]*role="([A-Z]+)"', meet.group()))


def meeting(mid):
    """-> (das, gold). das: [(da_id, speaker, text)] in time order. gold: [(sentence, owners, {da_id})].
    Regex, not an XML parser: the files are downloaded data, and each is one flat list of elements."""
    das = []
    for agent, role in roles(mid).items():
        wpath = os.path.join(AMI, "words", f"{mid}.{agent}.words.xml")
        if not os.path.exists(wpath):
            continue
        toks = re.findall(r'<(\w+) nite:id="([^"]+)"([^>]*?)(?:/>|>([^<]*)</\1>)', read(wpath))
        pos = {t[1]: i for i, t in enumerate(toks)}
        for da, a, b in re.findall(r'<dact nite:id="([^"]+)".*?words\.xml#id\(([^)]+)\)(?:\.\.id\(([^)]+)\))?', read(
                os.path.join(AMI, "dialogueActs", f"{mid}.{agent}.dialog-act.xml")), re.S):
            span = toks[pos[a]:pos[b or a] + 1]
            # AMI spells letters as "T_V_"; STT writes "TV".
            ws = [(re.sub(r"(?<=[A-Z])_", "", html.unescape(t[3])), 'punc="true"' in t[2]) for t in span if t[0] == "w"]
            text = "".join(w if p else " " + w for w, p in ws).strip()
            start = next((float(m) for t in span for m in re.findall(r'starttime="([\d.]+)"', t[2])), 0.0)
            if text:
                das.append((start, da, ROLE[role], text))
    das = [d[1:] for d in sorted(das)]
    abs_ = read(os.path.join(AMI, "abstractive", f"{mid}.abssumm.xml"))
    sec = re.search(r"<actions\b.*?</actions>", abs_, re.S)
    acts = re.findall(r'<sentence nite:id="([^"]+)">(.*?)</sentence>', sec.group(), re.S) if sec else []
    links = {}
    lpath = os.path.join(AMI, "extractive", f"{mid}.summlink.xml")
    for da, sid in re.findall(r'dialog-act\.xml#id\(([^)]+)\)"/>\s*<nite:pointer role="abstractive"\s+href="[^#]+#id\(([^)]+)\)', read(lpath) if os.path.exists(lpath) else ""):
        links.setdefault(sid, set()).add(da)
    gold = [(t, owners(t), links.get(sid, set())) for sid, t in ((s, html.unescape(x).strip()) for s, x in acts) if t and t != "*NA*"]
    return das, gold


def corpus(split):
    return {mid: meeting(mid) for mid, s in sorted(splits().items()) if s == split}


def sents_of(das):
    return [(spk, text) for _, spk, text in das]


def train(C=0.03, prune=0.02):
    """Logistic regression on the train split; writes actions_model.json (weights below `prune` are dropped)."""
    from sklearn.feature_extraction import DictVectorizer  # training only: the summarizer reads the JSON with plain Python
    from sklearn.linear_model import LogisticRegression
    X, y = [], []
    for das, gold in corpus("train").values():
        pos = set().union(*(links for _, _, links in gold))
        X += [dict.fromkeys(f, 1) for f in S.action_features(sents_of(das))]
        y += [d in pos for d, _, _ in das]
    dv = DictVectorizer()
    lr = LogisticRegression(C=C, class_weight="balanced", max_iter=5000).fit(dv.fit_transform(X), y)
    w = {k: round(float(v), 4) for k, v in zip(dv.feature_names_, lr.coef_[0]) if abs(v) >= prune}
    print(f"train: {len(y)} dialogue acts, {sum(y)} action items, {len(dv.feature_names_)} features, {len(w)} kept")
    return {"bias": round(float(lr.intercept_[0]), 4), "threshold": 0.5, "weights": dict(sorted(w.items())),
            "trained_on": "AMI manual annotations 1.6.2 (CC BY 4.0), scenario train split", "C": C}


def score(split, model, rule=None):
    """Gold action items with a named owner that some predicted item recovers (a linked dialogue act, same owner)."""
    r = dict.fromkeys(["meetings", "owned", "hit", "found", "team", "team_found", "pred", "tp", "near", "ms", "ms_max"], 0)
    for das, gold in corpus(split).values():
        sents = sents_of(das)
        t = time.perf_counter()
        items = rule(sents) if rule else [(i, who) for i, who, _, _ in S.action_items(sents, model)]
        dt = (time.perf_counter() - t) * 1000
        got = {das[i][0]: who for i, who in items}
        pos = set().union(*(links for _, _, links in gold))
        near = {das[j][0] for d in pos for i, x in enumerate(das) if x[0] == d for j in range(max(0, i - 2), min(len(das), i + 3))}
        r["meetings"] += 1; r["pred"] += len(items); r["tp"] += len(got.keys() & pos); r["near"] += len(got.keys() & near)
        r["ms"] += dt; r["ms_max"] = max(r["ms_max"], dt)
        for _, own, links in gold:
            if own:
                r["owned"] += 1; r["found"] += bool(links & got.keys()); r["hit"] += any(got[d] in own for d in links & got.keys())
            else:
                r["team"] += 1; r["team_found"] += bool(links & got.keys())
    return r


def first_person_rule(sents):
    """The iteration 1 rule, for comparison: every "I'll" / "I will" sentence, owner = speaker."""
    return [(i, spk) for i, (spk, s) in enumerate(sents) if S.COMMIT.search(s) and not s.endswith("?")]


def report(name, r):
    pct = lambda a, b: f"{r[a]}/{r[b]} = {r[a] / max(1, r[b]):.1%}"
    print(f"| {name} | {pct('hit', 'owned')} | {pct('found', 'owned')} | {pct('team_found', 'team')} | {pct('tp', 'pred')} | "
          f"{pct('near', 'pred')} | {r['pred'] / r['meetings']:.1f} | {r['ms'] / r['meetings']:.0f} / {r['ms_max']:.0f} ms |")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "eval"
    if cmd == "train":
        model = train()
        # The threshold is picked on dev only: among those giving at most 8 items per meeting, the highest one with the
        # best dev recall with the right owner.
        curve = {th: score("dev", {**model, "threshold": th}) for th in [x / 20 for x in range(2, 19)]}
        for th, r in curve.items():
            report(f"dev th={th:.2f}", r)
        best = max(r["hit"] for r in curve.values() if r["pred"] <= 8 * r["meetings"])
        model["threshold"] = max(th for th, r in curve.items() if r["hit"] == best and r["pred"] <= 8 * r["meetings"])
        with open(S.MODEL, "w") as f:
            json.dump(model, f, separators=(",", ":"))
        print(f"wrote {S.MODEL}: threshold {model['threshold']}, {os.path.getsize(S.MODEL) // 1024} KB")
        return
    split = sys.argv[2] if len(sys.argv) > 2 else "test"
    import tracemalloc
    tracemalloc.start()
    model = S.load_model()
    model_kb = tracemalloc.get_traced_memory()[0] // 1024
    tracemalloc.stop()  # tracing slows Python down several times, so latency is measured without it
    print(f"AMI {split} split, {sum(1 for s in splits().values() if s == split)} meetings. Model: actions_model.json, threshold "
          f"{model['threshold']}, {len(model['weights'])} weights, {model_kb} KB in memory once loaded")
    print("| Approach | Owned items recovered with right owner | Found (any owner) | Team items found | Precision (linked act) | "
          "Precision (within 2 acts) | Items / meeting | Latency mean / max |")
    print("|---|---|---|---|---|---|---|---|")
    report("first-person rule (iteration 1)", score(split, model, first_person_rule))
    r = score(split, model)
    report("AMI classifier + owner rules", r)
    k, n, z = r["hit"], r["owned"], 1.96  # Wilson 95% interval: the test split is small
    c, h = (k + z * z / 2) / (n + z * z), z * math.sqrt(k * (n - k) / n + z * z / 4) / (n + z * z)
    print(f"95% interval for recovered with right owner: {c - h:.0%} to {c + h:.0%}")
    das = max((d for d, _ in corpus(split).values()), key=len)
    tracemalloc.start()
    S.action_items(sents_of(das), model)
    print(f"Longest meeting ({len(das)} dialogue acts): peak Python heap {tracemalloc.get_traced_memory()[1] // 1024} KB for action_items; "
          f"whole eval process peak RSS {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20 if sys.platform == 'darwin' else 1 << 10):.0f} MB")


if __name__ == "__main__":
    main()
