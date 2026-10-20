#!/usr/bin/env python3
"""Check docs/re and agent/goal.md against agent/goal.md's reverse-engineering and parity rules.

  python3 scripts/check_re_docs.py              run every check (the first one reads the extracted
                                                Wispr bundle on Pavel's Mac, see WISPR below)
  python3 scripts/check_re_docs.py --no-bundle  checks 2 and 3 only, for machines without the bundle (CI)
  python3 scripts/check_re_docs.py --self-test  assert-based self-check, needs nothing outside the repo

1. No copied Wispr strings. A quoted span (`...`, "..." or curly quotes) of 20+ chars that holds a
   space and is not a file name is prose. Prose must not occur verbatim in the Swift helper's
   `strings` dump, the extracted asar or the ax-inspect*.mjs dev scripts. Cite path + symbol or offset and paraphrase instead.
   Symbols (no spaces) are fine.
2. No Wispr backend endpoints. The repo is public and shepetal is local-only, so Wispr's API,
   inference and telemetry hosts, its Baseten and Modal hosts and its fine-tune IDs stay out.
   Wispr's public web pages may be cited.
3. Inventory. Every docs/re/feature-inventory.md row is P0, P1, P2 or n/a. An n/a row's plan reads
   `n/a <category>: <reason>` with a category the goal allows. The Counts section matches the table.

Exit status 1 when any rule is broken.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INVENTORY = ROOT / "docs/re/feature-inventory.md"
RESOURCES = pathlib.Path("/Applications/Wispr Flow.app/Contents/Resources")  # read only
WISPR = (pathlib.Path("/Users/sorcecoder/shepetal-re/insertion/helper-strings.txt"),
         pathlib.Path("/Users/sorcecoder/shepetal-re/asar/.webpack"),
         *(RESOURCES / f"ax-inspect{s}.mjs" for s in ("", "-lib", "-server")))
# The n/a categories agent/goal.md allows, spelled as in the parity ledger.
NA_CATEGORIES = {"billing", "subscriptions", "referrals", "telemetry", "remote-flags", "ab-tests", "account-admin"}
PRIORITIES = ("P0", "P1", "P2", "n/a")

# Separate patterns, so a "quote" inside a `code span` is checked on its own too.
SPANS = [re.compile(p) for p in (r"`([^`\n]+)`", r"\"([^\"\n]+)\"", r"“([^”\n]+)”")]
FILE_NAME = re.compile(r"^[\w ./~-]+\.\w{2,4}$")
HOST = re.compile(r"[\w*-]+(?:\.[\w*-]+)+")
PRIVATE_HOST = re.compile(r"(?:^|\.)(?:wisprflow\.ai|wisprflow\.com|wispr\.ai|baseten\.co|modal\.direct|modal\.run)$")
PUBLIC_HOSTS = {"wisprflow.ai", "docs.wisprflow.ai", "roadmap.wisprflow.ai", "notes.wisprflow.ai", "dl.wisprflow.com"}
FINE_TUNE = re.compile(r"\bopenpipe:[\w.-]+")
ROW = re.compile(r"^\|\s*(F\d+)\s*\|(.*)\|\s*$", re.M)
COUNT = re.compile(r"^- (P0|P1|P2|n/a): (.*) = \*\*(\d+)\*\*$", re.M)
TOTAL = re.compile(r"^- Total: \*\*(\d+)\*\*$", re.M)


def prose_spans(text):
    """Yield (line, span) for every quoted prose span; an ellipsis splits a span into parts."""
    for n, line in enumerate(text.splitlines(), 1):
        for span in (s for pattern in SPANS for s in pattern.findall(line)):
            for part in re.split(r"\.\.\.|…", span):
                part = part.strip()
                if len(part) >= 20 and " " in part and not FILE_NAME.match(part):
                    yield n, part


def copied(text, wispr):
    return [(n, s) for n, s in prose_spans(text) if s in wispr]


def endpoints(text):
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        out += [(n, h) for h in HOST.findall(line) if PRIVATE_HOST.search(h) and h not in PUBLIC_HOSTS]
        out += [(n, m) for m in FINE_TUNE.findall(line)]
    return out


def inventory_errors(text):
    errors, seen, table = [], set(), {p: set() for p in PRIORITIES}
    for fid, rest in ROW.findall(text):
        cols = [c.strip() for c in rest.split("|")]
        if fid in seen:
            errors.append(f"{fid}: duplicate ID")
        seen.add(fid)
        if len(cols) != 6:
            errors.append(f"{fid}: expected | ID | Feature | Wispr | Cloud | plan | Pri | Evidence |")
            continue
        plan, pri = cols[3], cols[4]
        if pri not in PRIORITIES:
            errors.append(f"{fid}: priority {pri!r} is not one of {', '.join(PRIORITIES)}")
            continue
        table[pri].add(fid)
        m = re.match(r"n/a ([\w-]+): \S", plan)
        if pri == "n/a" and not (m and m.group(1) in NA_CATEGORIES):
            errors.append(f"{fid}: an n/a plan must read 'n/a <category>: <reason>' with a category in {sorted(NA_CATEGORIES)}")
    listed = {}
    for pri, ids, n in COUNT.findall(text):
        listed[pri] = set(re.findall(r"F\d+", ids))
        if len(listed[pri]) != int(n):
            errors.append(f"Counts: the {pri} line lists {len(listed[pri])} IDs but says {n}")
    for pri in PRIORITIES:
        if listed.get(pri, set()) != table[pri]:
            errors.append(f"Counts: the {pri} line does not match the table ({sorted(table[pri] ^ listed.get(pri, set()))})")
    total = TOTAL.search(text)
    if not total or int(total.group(1)) != len(seen):
        errors.append(f"Counts: Total does not match the {len(seen)} rows")
    return errors


def load_wispr():
    missing = [str(p) for p in WISPR if not p.exists()]
    if missing:
        return None, [f"missing {p}: the copied-string check needs the extracted Wispr bundle" for p in missing]
    files = [p for root in WISPR for p in ([root] if root.is_file() else sorted(root.rglob("*"))) if p.is_file()]
    return "\n".join(p.read_text(errors="ignore") for p in files), []


def self_test():
    wispr = "a Timer armed to spot a missed paste b\nPingHelperForTextBox"
    assert copied('helper says "Timer armed to spot a missed paste" here', wispr) == [(1, "Timer armed to spot a missed paste")]
    assert copied("`...Timer armed to spot a missed paste`", wispr), "an ellipsis must not hide a copied part"
    assert copied("`PingHelperForTextBox`, `bundle-dir/Some Helper.app`", wispr + " bundle-dir/Some Helper.app") == []
    assert copied('`log: "Timer armed to spot a missed paste"`', wispr), "a quote inside a code span is checked too"
    assert copied('"our own paraphrase of the timer"', wispr) == []
    assert endpoints("host `model-x1.grpc.api.baseten.co` and `svc--x.us-east.modal.direct`") == [
        (1, "model-x1.grpc.api.baseten.co"), (1, "svc--x.us-east.modal.direct")]
    assert endpoints("wss://api-x.wisprflow.ai/ and `chain-*.api.baseten.co`")
    assert endpoints("model `openpipe:llama-x-1`") == [(1, "openpipe:llama-x-1")]
    assert endpoints("https://docs.wisprflow.ai/articles/1, https://wisprflow.ai/post/x, `index.js`") == []
    good = ("| F01 | a | M | n | local | P0 | e |\n| F02 | b | M | y | n/a billing: paid plans only | n/a | e |\n"
            "- P0: F01 = **1**\n- n/a: F02 = **1**\n- Total: **2**\n")
    assert inventory_errors(good) == []
    assert any("priority 'Skip'" in e for e in inventory_errors(good.replace("| P0 |", "| Skip |")))
    assert any("n/a plan" in e for e in inventory_errors(good.replace("n/a billing:", "n/a sharing:")))
    assert any("n/a plan" in e for e in inventory_errors(good.replace("n/a billing: paid plans only", "none")))
    assert any("lists 1 IDs but says 2" in e for e in inventory_errors(good.replace("F01 = **1**", "F01 = **2**")))
    assert any("does not match" in e for e in inventory_errors(good.replace("- P0: F01", "- P1: F01")))
    assert any("Total" in e for e in inventory_errors(good.replace("**2**", "**3**")))
    assert any("duplicate" in e for e in inventory_errors(good + "| F01 | a | M | n | local | P0 | e |\n"))
    print("self-test ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--no-bundle", action="store_true", help="skip check 1, which needs the extracted Wispr bundle")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    docs = sorted((ROOT / "docs/re").glob("*.md")) + [ROOT / "agent/goal.md"]
    wispr, errors = (None, []) if args.no_bundle else load_wispr()
    if args.no_bundle:
        print("SKIP check 1 (copied Wispr strings): --no-bundle, the extracted Wispr bundle is not on this machine")
    spans = 0
    for doc in docs:
        text, name = doc.read_text(), doc.relative_to(ROOT)
        spans += sum(1 for _ in prose_spans(text))
        if wispr is not None:
            errors += [f"{name}:{n}: copied Wispr string {s!r}" for n, s in copied(text, wispr)]
        errors += [f"{name}:{n}: Wispr backend endpoint {h!r}" for n, h in endpoints(text)]
    errors += [f"{INVENTORY.relative_to(ROOT)}: {e}" for e in inventory_errors(INVENTORY.read_text())]
    for e in errors:
        print("FAIL", e)
    print(f"{len(docs)} docs, {spans} quoted prose spans, {len(ROW.findall(INVENTORY.read_text()))} inventory rows: "
          + (f"{len(errors)} problems" if errors else "ok"))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
