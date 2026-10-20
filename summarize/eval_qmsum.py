"""Score the summarizer on real meetings: QMSum general summaries + AMI owner-labelled action items.

Data (text only, fetched once into .cache, which is gitignored):
  QMSum (MIT; 232 meetings = 137 AMI design meetings, 59 ICSI research meetings, 36 parliament committees):
    git clone -q --depth 1 --filter=blob:none --sparse https://github.com/Yale-LILY/QMSum.git .cache/qmsum
    git -C .cache/qmsum sparse-checkout set data/ALL/train data/ALL/val data/ALL/test
  AMI manual annotations (CC BY 4.0); their abstractive summaries list action items that name the owner's role:
    mkdir -p .cache/ami && curl -sSLo .cache/ami/m.zip https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip
    unzip -q -o .cache/ami/m.zip 'abstractive/*' -d .cache/ami
Usage: .venv/bin/python -I eval_qmsum.py [APPROACH]    (default textrank-tfidf)
"""
import glob, html, json, os, re, sys, time, resource

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # -I drops the script dir; add back only our own code dir, never a data dir
import summarize as S

QMSUM = os.path.join(HERE, ".cache", "qmsum", "data", "ALL")
AMI = os.path.join(HERE, ".cache", "ami", "abstractive")
# AMI summaries name owners by role ("The marketing expert will ..."); QMSum labels AMI speakers with the same roles.
ROLES = [(r"project manager|\bpm\b", "Project Manager"), (r"industrial|\bid\b", "Industrial Designer"),
         (r"interface|\bui\b", "User Interface"), (r"marketing", "Marketing")]
STOP = set("the a an and or of to for on in at by with will would be is are was were that this these those it its "
           "their his her them they he she we you i our your all team group members member project manager industrial "
           "designer user interface marketing expert specialist work working next meeting".split())


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


def owners(sentence):
    """Roles named in the subject ("The ID and UI will ...") only; "The team will decide how the interface ..." has none."""
    subj = re.split(r"\b(?:will|were|was|are|is|has|have|should|must|needs?)\b", sentence.lower())[0]
    return {role for key, role in ROLES if re.search(key, subj)}


def stems(s):
    return {w[:5] for w in S.words(s) if w not in STOP and len(w) > 2}  # ponytail: 5-letter prefix as stemmer


def matches(gold, item):
    """Predicted (owner, task, due) recovers a gold AMI action: same owner role and >= 2 shared content stems."""
    return item[0] in owners(gold) and len(stems(gold) & stems(item[1])) >= 2


def gold_actions(mid):
    p = os.path.join(AMI, mid + ".abssumm.xml")
    if not os.path.exists(p):
        return []
    # Regex, not an XML parser: the file is downloaded data, and the format is one flat <actions> list.
    sec = re.search(r"<actions\b.*?</actions>", open(p, encoding="latin-1").read(), re.S)
    sents = re.findall(r"<sentence\b[^>]*>(.*?)</sentence>", sec.group(), re.S) if sec else []
    return [t for t in (html.unescape(x).strip() for x in sents) if t and t != "*NA*"]


def main():
    approach = sys.argv[1] if len(sys.argv) > 1 else "textrank-tfidf"
    summarize = S.load(approach)
    rows, act = {}, {"gold": 0, "group": 0, "owner_any": 0, "hit": 0, "pred": 0, "meetings": 0}
    for path in sorted(glob.glob(os.path.join(QMSUM, "*", "*.json"))):
        mid = os.path.basename(path)[:-5]
        d = json.load(open(path))
        text = transcript(d["meeting_transcripts"])
        t = time.perf_counter()
        sents = S.parse(text)
        ov, pts = summarize(text, sents)
        acts = S.actions(sents)
        md = S.render(ov, pts, S.decisions(sents), acts)
        dt = time.perf_counter() - t
        ref = d["general_query_list"][0]["answer"]
        n = len(S.words(md))
        lead = " ".join(S.words(" ".join(s for _, s in sents))[:n])  # LEAD baseline: first n words of the meeting
        rows.setdefault(domain(mid), []).append((*S.rouge(ref, md), *S.rouge(ref, lead), dt, len(sents), n, len(S.words(ref))))
        gold = gold_actions(mid) if domain(mid) == "AMI" else []
        if gold:
            act["meetings"] += 1
            act["pred"] += len(acts)
            for g in gold:
                if not owners(g):
                    act["group"] += 1  # "The team will ..." has no single owner to check
                    continue
                act["gold"] += 1
                act["owner_any"] += any(a[0] in owners(g) for a in acts)
                act["hit"] += any(matches(g, a) for a in acts)
    print(f"{approach}: ROUGE F1 vs QMSum 'summarize the whole meeting' answers (full output / LEAD baseline at equal length)")
    print("| Corpus | Meetings | R-1 | R-2 | R-L | LEAD R-1 | LEAD R-2 | LEAD R-L | Sentences | Output / ref words | Latency mean / max |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for name, rs in sorted(rows.items()) + [("All", [r for rs in rows.values() for r in rs])]:
        m = [sum(r[i] for r in rs) / len(rs) for i in range(10)]
        print(f"| {name} | {len(rs)} | {m[0]:.3f} | {m[1]:.3f} | {m[2]:.3f} | {m[3]:.3f} | {m[4]:.3f} | {m[5]:.3f} | "
              f"{m[7]:.0f} | {m[8]:.0f} / {m[9]:.0f} | {m[6]*1000:.0f} / {max(r[6] for r in rs)*1000:.0f} ms |")
    g = max(1, act["gold"])
    print(f"\nAMI action items ({act['meetings']} meetings with annotations): {act['gold']} with a named owner, "
          f"{act['group']} assigned to the whole team (not scored). Predicted items: {act['pred']}.")
    print(f"Recovered with right owner and matching task: {act['hit']}/{act['gold']} = {act['hit']/g:.1%}. "
          f"Upper bound (any item from the right owner): {act['owner_any']}/{act['gold']} = {act['owner_any']/g:.1%}.")
    print(f"Peak RSS: {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20):.0f} MB")


if __name__ == "__main__":
    main()
