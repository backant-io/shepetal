#!/usr/bin/env python3
"""The Mac release guard (docs/install-and-update.md 4): a release must never ship a version or build that is not
above the last published one, because Sparkle would then offer it to nobody, and build 1 from a shallow clone would
strand every user. Prints VERSION on success; fails loudly otherwise.

  release_guard.py --tag v0.2.0-mac --build 512 [--main origin/main] [--previous appcast.xml] [--repo DIR]
  release_guard.py --self-test     hermetic: a temp git repo and fixture appcasts

--main '' skips the "tag is on main" check (the PR dry run). --previous is the appcast.xml of the newest published,
non-pre-release v*-mac release (none before the first one).
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-mac$")
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class GuardError(Exception):
    pass


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def newest(appcast_path):
    """(version tuple, build) of the newest item in an appcast, by build number."""
    items = []
    for item in ET.parse(appcast_path).getroot().iter("item"):
        enclosure = item.find("enclosure")
        build = item.findtext(SPARKLE + "version") or (enclosure is not None and enclosure.get(SPARKLE + "version"))
        short = item.findtext(SPARKLE + "shortVersionString") or (
            enclosure is not None and enclosure.get(SPARKLE + "shortVersionString"))
        if build and short:
            items.append((int(build), tuple(int(p) for p in short.split("."))))
    if not items:
        raise GuardError(f"{appcast_path} has no item with sparkle:version and sparkle:shortVersionString")
    build, version = max(items)
    return version, build


def check(tag, build, repo=".", main="origin/main", previous=None):
    m = TAG.match(tag)
    if not m:
        raise GuardError(f"tag {tag!r} is not v<major>.<minor>.<patch>-mac")
    version = tuple(int(p) for p in m.groups())
    if git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() != "false":
        raise GuardError("the clone is shallow, so the build number (commit count) would be wrong: fetch-depth: 0")
    if main and git(repo, "merge-base", "--is-ancestor", "HEAD", main).returncode != 0:
        raise GuardError(f"HEAD is not on {main}: release only from main")
    if previous:
        last_version, last_build = newest(previous)
        if not version > last_version:
            raise GuardError(f"version {'.'.join(map(str, version))} is not above the published "
                             f"{'.'.join(map(str, last_version))}")
        if not build > last_build:
            raise GuardError(f"build {build} is not above the published build {last_build}")
    return ".".join(map(str, version))


def appcast(version, build):
    return (f'<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="{SPARKLE[1:-1]}"><channel><item>'
            f"<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
            '<enclosure url="https://example.invalid/a.dmg" length="1" type="application/octet-stream"/>'
            "</item></channel></rss>")


def self_test():
    failures = []

    def expect(ok, label, **kw):
        try:
            check(**kw)
            passed = True
        except GuardError:
            passed = False
        if passed != ok:
            failures.append(f"{label}: wanted {'pass' if ok else 'fail'}")

    with tempfile.TemporaryDirectory() as t:
        repo = os.path.join(t, "repo")
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        run = lambda *a, cwd=repo: subprocess.run(a, cwd=cwd, env=env, check=True, capture_output=True)  # noqa: E731
        os.makedirs(repo)
        run("git", "init", "-q", "-b", "main")
        for n in range(3):
            run("git", "commit", "-q", "--allow-empty", "-m", f"c{n}")
        prev = os.path.join(t, "appcast.xml")
        with open(prev, "w") as f:
            f.write(appcast("0.2.0", 100))

        base = dict(repo=repo, main="main")
        expect(True, "a tag on main, above the published release", tag="v0.3.0-mac", build=101, previous=prev, **base)
        expect(True, "the first release (nothing published yet)", tag="v0.1.0-mac", build=1, **base)
        for bad in ["v0.3.0", "0.3.0-mac", "v0.3-mac", "v0.3.0-mac-rc1", "v0.3.0-linux"]:
            expect(False, f"tag format {bad}", tag=bad, build=101, **base)
        expect(False, "the same version again", tag="v0.2.0-mac", build=101, previous=prev, **base)
        expect(False, "an older version", tag="v0.1.9-mac", build=101, previous=prev, **base)
        expect(False, "the same build again", tag="v0.3.0-mac", build=100, previous=prev, **base)
        expect(False, "a lower build", tag="v0.3.0-mac", build=99, previous=prev, **base)
        expect(True, "0.10.0 is above 0.9.0 (numbers, not strings)", tag="v0.10.0-mac", build=101,
               previous=_write(t, "nine.xml", appcast("0.9.0", 100)), **base)

        run("git", "checkout", "-q", "-b", "side")
        run("git", "commit", "-q", "--allow-empty", "-m", "off main")
        expect(False, "a commit that is not on main", tag="v0.3.0-mac", build=101, **base)
        expect(True, "--main '' (PR dry run) skips the ancestry check", tag="v0.3.0-mac", build=101, repo=repo, main="")

        shallow = os.path.join(t, "shallow")
        run("git", "clone", "-q", "--depth", "1", "--branch", "main", f"file://{repo}", shallow, cwd=t)
        expect(False, "a shallow clone", tag="v0.3.0-mac", build=1, repo=shallow, main="origin/main")

    if failures:
        print("release_guard self-test FAILED:\n  " + "\n  ".join(failures))
        sys.exit(1)
    print("release_guard self-test ok")


def _write(directory, name, text):
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write(text)
    return path


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--tag")
    p.add_argument("--build", type=int)
    p.add_argument("--repo", default=".")
    p.add_argument("--main", default="origin/main")
    p.add_argument("--previous")
    p.add_argument("--self-test", action="store_true")
    a = p.parse_args()
    if a.self_test:
        return self_test()
    if not a.tag or a.build is None:
        p.error("--tag and --build are required")
    try:
        print(check(a.tag, a.build, a.repo, a.main, a.previous))
    except GuardError as e:
        print(f"release guard: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
