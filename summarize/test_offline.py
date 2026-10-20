"""Goal rule 5 / Verification "Privacy": the default summary path makes no network request.

Run from summarize/: .venv/bin/python -m unittest test_offline -v
A fresh interpreter blocks every socket connect and DNS lookup before `summarize` is imported, then runs
load -> summarize -> decisions -> actions -> render on every fixture. A download added to the import or to
the default path (an NLTK corpus, a tokenizer) raises there and fails this test.
"""
import os, subprocess, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))

GUARD = r"""
import glob, os, socket, sys
attempts = []
def refuse(*a, **k):
    attempts.append(repr(a[:2]))
    raise OSError("network blocked by test_offline")
socket.socket.connect = socket.socket.connect_ex = refuse
socket.create_connection = socket.getaddrinfo = socket.gethostbyname = refuse
sys.path.insert(0, sys.argv[1])
import summarize as S
summarize = S.load("textrank-tfidf")
n = 0
for path in sorted(glob.glob(os.path.join(sys.argv[1], "fixtures", "*.txt"))):
    text = open(path).read()
    sents = S.parse(text)
    md = S.render(*summarize(text, sents), S.decisions(sents), S.actions(sents))
    assert "## Action items" in md, path
    n += 1
assert n >= 3, n
print(f"offline ok: {n} fixtures, {len(attempts)} network attempts")
sys.exit(1 if attempts else 0)
"""


class Offline(unittest.TestCase):
    def run_guarded(self, code):
        return subprocess.run([sys.executable, "-I", "-c", code, HERE], capture_output=True, text=True, timeout=120)

    def test_default_summary_makes_no_network_request(self):
        r = self.run_guarded(GUARD)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("offline ok", r.stdout)
        self.assertIn(", 0 network attempts", r.stdout)

    def test_the_guard_catches_a_request(self):
        # The guard itself must fail a run that tries to connect, or the test above proves nothing.
        r = self.run_guarded(GUARD.replace("import summarize as S", "import summarize as S\nimport urllib.request\n"
                                           "try: urllib.request.urlopen('http://example.org', timeout=1)\nexcept Exception: pass"))
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
