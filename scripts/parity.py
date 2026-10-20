#!/usr/bin/env python3
"""Compute shepetal's Wispr Flow parity from docs/parity.md (see agent/goal.md, "The finish line").

  python3 scripts/parity.py                                 check the ledger, print coverage
  python3 scripts/parity.py --completeness MAP IDENTIFIERS  also fail on unmapped Wispr identifiers
                                                            and on map entries missing from the lists
  python3 scripts/parity.py --self-test                     assert-based self-check

Exit status 1 when any rule is broken. The ledger syntax is described at the top of docs/parity.md.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLATFORMS = ("Mac", "Linux", "iPhone")
VALUES = {"done", "hand-test", "confirmed", "impossible", "n/a", "outside", "todo"}
AUTOMATED = {"done", "hand-test", "confirmed", "impossible", "n/a", "outside"}
CONFIRMED = AUTOMATED - {"hand-test"}
DESKTOP = {"M", "W"}  # inventory Wispr-column letters that map to the Mac and Linux columns (goal "Platform mapping")
NA_CATEGORIES = {"billing", "subscriptions", "referrals", "telemetry", "remote-flags", "ab-tests", "account-admin"}
# A docs/manual-test.md step id (M-FN-1, I-DICT-1, L-KEY-2, MEET-3). A cell that waits on one is hand-test, not done (#41).
HAND_STEP = re.compile(r"\b(?:[MIL]-[A-Z]+-\d+|MEET-\d+)\b")
ROW = re.compile(r"^\|\s*(F\d+)\s*\|(.*)\|\s*$", re.M)


def rows(text):
    for m in ROW.finditer(text):
        yield m.group(1), [c.strip() for c in m.group(2).split("|")]


def evidence(notes):
    """Map each platform to the text of its `Mac:` / `Linux:` / `iPhone:` / `All:` segments."""
    out = dict.fromkeys(PLATFORMS, "")
    for segment in notes.split(";"):
        label, _, body = segment.partition(":")
        label = label.strip()
        for p in PLATFORMS if label == "All" else [label] if label in PLATFORMS else []:
            out[p] += " " + body
    return out


def check(inventory, ledger):
    """Return (errors, cell values) for a ledger against the inventory."""
    errors, ledger_ids, cells = [], set(), []
    wispr = {fid: set(cols[1].split()) for fid, cols in rows(inventory)}
    # A malformed Wispr column ("M,W", "") holds no desktop letter, so outside would pass silently.
    errors += [f"{fid}: inventory Wispr column must be M, W and/or i separated by spaces, got {' '.join(sorted(w))!r}"
               for fid, w in wispr.items() if not w or w - DESKTOP - {"i"}]
    for fid, cols in rows(ledger):
        if fid in ledger_ids:
            errors.append(f"{fid}: duplicate row")
            continue
        ledger_ids.add(fid)
        if len(cols) != 5:
            errors.append(f"{fid}: expected | F-ID | Feature | Mac | Linux | iPhone | Evidence / notes |")
            continue
        ev = evidence(cols[4])
        for p, value in zip(PLATFORMS, cols[1:4]):
            cells.append(value)
            e = ev[p]
            if value not in VALUES:
                errors.append(f"{fid} {p}: unknown value {value!r}")
            elif value == "done" and not (re.search(r"`[^`]+`", e) and re.search(r"#\d+", e)):
                errors.append(f"{fid} {p}: done needs a `test name` and a PR number (#N)")
            elif value == "done" and HAND_STEP.search(e):
                errors.append(f"{fid} {p}: done cites hand step {HAND_STEP.search(e).group()}; a cell that waits on "
                              "docs/manual-test.md is hand-test")
            elif value == "impossible" and not re.search(r"https?://\S+", e):
                errors.append(f"{fid} {p}: impossible needs a doc citation (URL)")
            elif value == "n/a":
                m = re.search(r"\bn/a ([\w-]+): *\w", e)
                if not m or m.group(1) not in NA_CATEGORIES:
                    errors.append(f"{fid} {p}: n/a needs 'n/a <category>: <reason>' with a category in {sorted(NA_CATEGORIES)}")
            elif value == "outside" and (p == "iPhone" or DESKTOP & wispr.get(fid, set())):
                errors.append(f"{fid} {p}: outside needs a Mac or Linux cell whose inventory Wispr column has no M or W "
                              "(an iPhone cell is never outside; use impossible)")
    inventory_ids = set(wispr)
    errors += [f"{fid}: in the inventory but missing from the ledger" for fid in sorted(inventory_ids - ledger_ids)]
    errors += [f"{fid}: in the ledger but not in the inventory" for fid in sorted(ledger_ids - inventory_ids)]
    return errors, cells


def coverage(cells):
    """(automated %, confirmed %) over all cells."""
    n = len(cells) or 1
    return 100 * sum(v in AUTOMATED for v in cells) / n, 100 * sum(v in CONFIRMED for v in cells) / n


def completeness(map_text, identifiers, ledger_ids):
    """identifiers: {(category, name)}. Map lines: category<TAB>identifier<TAB>F-ID|internal<TAB>reason."""
    errors, mapped = [], set()
    for n, line in enumerate(map_text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t") + ["", ""]
        category, name, target, reason = cols[0], cols[1], cols[2], cols[3].strip()
        if (category, name) not in identifiers:
            # The map covers every identifier, so this catches truncated lists as well as stale entries.
            errors.append(f"map line {n}: {category}: {name} is not in the identifier lists")
        elif target == "internal" and not reason:
            errors.append(f"map line {n}: internal needs a reason")
        elif target != "internal" and target not in ledger_ids:
            errors.append(f"map line {n}: {target!r} is not an F-ID in the ledger")
        else:
            mapped.add((category, name))
    errors += [f"unmapped {c}: {i}" for c, i in sorted(identifiers - mapped)]
    return errors


def read_identifiers(directory):
    ids = set()
    for path in sorted(pathlib.Path(directory).glob("*-*.txt")):
        category = re.fullmatch(r"(.+)-\d+\.txt", path.name).group(1)
        ids |= {(category, line) for line in path.read_text().splitlines() if line}
    return ids


def self_test():
    inv = "| F01 | a | M | n | x | P0 | y |\n| F02 | b | M | n | x | P0 | y |\n"
    good = ("| F01 | a | done | impossible | n/a | Mac: `HotkeyTests.testHold` #3; "
            "Linux: https://www.kernel.org/doc/x; iPhone: n/a billing: store only |\n"
            "| F02 | b | hand-test | todo | confirmed | |\n")
    errors, cells = check(inv, good)
    assert errors == [], errors
    assert coverage(cells) == (500 / 6, 400 / 6), coverage(cells)

    def fails(ledger, needle):
        errors = check(inv, ledger)[0]
        assert any(needle in e for e in errors), (needle, errors)

    fails(good.splitlines()[0], "F02: in the inventory but missing")
    fails(good + "| F03 | c | todo | todo | todo | |\n", "F03: in the ledger but not in the inventory")
    fails(good.replace("#3", ""), "F01 Mac: done needs")
    fails(good.replace("`HotkeyTests.testHold`", "HotkeyTests.testHold"), "F01 Mac: done needs")
    fails(good.replace("https://www.kernel.org/doc/x", "the kernel forbids it"), "F01 Linux: impossible needs")
    fails(good.replace("n/a billing", "n/a cloud-sync"), "F01 iPhone: n/a needs")
    fails(good.replace("Mac: `HotkeyTests", "Linux: `HotkeyTests"), "F01 Mac: done needs")  # no cross-platform evidence
    fails(good.replace("n/a billing: store only", "n/a billing"), "F01 iPhone: n/a needs")
    fails(good.replace("| todo |", "| wip |"), "unknown value 'wip'")
    for step in ("M-NS-1", "I-DICT-1", "L-KEY-2", "MEET-3"):  # done may not wait on a hand step (#41)
        fails(good.replace("#3;", f"#3, see {step};"), f"F01 Mac: done cites hand step {step}")
    for text in ("UTF-8", "SHA-256", "F01-2"):  # look-alikes that are not step ids
        assert check(inv, good.replace("#3;", f"#3 {text};"))[0] == [], text

    # outside: only for a column the feature's Wispr platforms don't map to.
    ios_inv = inv + "| F09 | k | i | y | x | P2 | y |\n"
    ios = good + "| F09 | k | outside | outside | todo | |\n"
    errors, cells = check(ios_inv, ios)
    assert errors == [], errors
    assert coverage(cells[-3:]) == (200 / 3, 200 / 3), coverage(cells[-3:])
    fails(good.replace("| hand-test |", "| outside |"), "F02 Mac: outside needs")  # Wispr ships it on Mac
    for wispr in ("M", "W", "M W i"):  # any desktop letter keeps Mac and Linux inside the mapping
        errors = check(ios_inv.replace("| k | i |", f"| k | {wispr} |"), ios)[0]
        assert any("F09 Mac: outside needs" in e for e in errors), (wispr, errors)
        assert any("F09 Linux: outside needs" in e for e in errors), (wispr, errors)
    for wispr in ("M,W", "MW", "", "mac win"):  # a malformed column must not let outside through
        errors = check(ios_inv.replace("| k | i |", f"| k | {wispr} |"), ios)[0]
        assert any("F09: inventory Wispr column must be" in e for e in errors), (wispr, errors)
    errors = check(ios_inv, ios.replace("| todo | |", "| outside | |"))[0]
    assert any("F09 iPhone: outside needs" in e for e in errors), errors

    ids = {("flags", "x-flag"), ("events", "y_event")}
    full = "flags\tx-flag\tF01\nevents\ty_event\tinternal\tserver-side metric\n"
    assert completeness(full, ids, {"F01"}) == []
    assert completeness(full.splitlines()[0], ids, {"F01"}) == ["unmapped events: y_event"]
    assert completeness(full, {("flags", "x-flag")}, {"F01"}) == ["map line 2: events: y_event is not in the identifier lists"]
    assert any("internal needs a reason" in e for e in completeness(full.replace("\tserver-side metric", ""), ids, {"F01"}))
    assert any("not an F-ID" in e for e in completeness(full, ids, {"F02"}))
    print("self-test ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--completeness", nargs=2, metavar=("MAP", "IDENTIFIERS_DIR"))
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    ledger = (ROOT / "docs/parity.md").read_text()
    errors, cells = check((ROOT / "docs/re/feature-inventory.md").read_text(), ledger)
    if args.completeness:
        map_path, ids_dir = args.completeness
        ids = read_identifiers(ids_dir)
        if not ids:
            errors.append(f"no identifiers found in {ids_dir}")
        errors += completeness(pathlib.Path(map_path).read_text(), ids, {fid for fid, _ in rows(ledger)})
    for e in errors:
        print("FAIL", e)
    auto, conf = coverage(cells)
    print(f"automated coverage: {auto:.1f}% of {len(cells)} cells")
    print(f"confirmed coverage: {conf:.1f}% of {len(cells)} cells")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
