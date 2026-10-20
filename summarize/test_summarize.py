"""Run from summarize/: .venv/bin/python -m unittest -v"""
import glob, os, re, sys, unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import summarize as S
import eval_qmsum as E


class DefaultSummarizer(unittest.TestCase):
    def test_runs_without_torch(self):
        # The default path ships on every platform with no model runtime; torch is only for the optional MiniLM ranker.
        text = open(os.path.join(HERE, "fixtures", "01_release_planning.txt")).read()
        sents = S.parse(text)
        with patch.dict(sys.modules, {"torch": None, "transformers": None}):  # importing either now raises
            overview, points = S.load("textrank-tfidf")(text, sents)
        self.assertTrue(overview)
        self.assertGreaterEqual(len(points), 3)

    def test_fixtures_match_committed_summaries(self):
        # docs/summarization.md cites out/textrank-tfidf/*.md and its ROUGE; a change to ranking or rules must regenerate them on purpose.
        for path in sorted(glob.glob(os.path.join(HERE, "fixtures", "*.txt"))):
            text, sents = fixture(path)
            md = S.render(*S.load("textrank-tfidf")(text, sents), S.decisions(sents), S.actions(sents))
            with self.subTest(os.path.basename(path)):
                self.assertEqual(md, open(os.path.join(HERE, "out", "textrank-tfidf", os.path.basename(path)[:-4] + ".md")).read())

    def test_fixture_action_items_keep_owner_and_due(self):
        # Goal: action items are recovered with the right owner; the due date is what makes them schedulable.
        for path in sorted(glob.glob(os.path.join(HERE, "fixtures", "*.txt"))):
            _, sents = fixture(path)
            got = [(o, d) for o, _, d in S.actions(sents)]
            ref = re.findall(r"^- (\w+): .*?(?:\(due ([^)]+)\))?\.?$", open(path[:-4] + ".ref.md").read().split("## Action items")[1], re.M)
            with self.subTest(os.path.basename(path)):
                self.assertTrue(ref)
                for owner, due in ref:
                    self.assertTrue(any(o == owner and d.startswith(due) for o, d in got), (owner, due, got))

    def test_question_is_not_a_commitment(self):
        self.assertEqual(S.actions([("Tom", "So I'll send the notes tomorrow?")]), [])
        self.assertEqual(S.actions([("Tom", "I'll send the notes tomorrow.")]), [("Tom", "send the notes", "tomorrow")])

    def test_decision_keeps_the_clause_after_the_keyword(self):
        self.assertEqual(S.decisions([("Ana", "Okay, decision: we ship the beta on Friday.")]), ["We ship the beta on Friday."])

    def test_decision_sentence_ending_at_the_keyword_is_skipped(self):
        # One such line in a real STT transcript used to raise IndexError and lose the whole summary.
        sents = S.parse("Alice: After a long talk we have finally reached our decision:\nBob: Fine.")
        self.assertEqual(S.decisions(sents), [])

    def test_empty_transcript_gives_an_empty_summary(self):
        # Cancelled or silent recordings are kept (goal rule 4), so the summarizer sees empty text.
        self.assertEqual(S.load("textrank-tfidf")("", S.parse("")), ("", []))

    def test_undiarized_transcript_is_summarized(self):
        # An iPhone in-person mic recording has no speaker labels; it still gets a summary and action items.
        text = ("We need to ship the release by Friday and I will send the notes tomorrow. "
                "The release notes cover the new onboarding flow and the audio crash fix for older phones. "
                "The audio crash fix is merged and the regression suite passed on every device we own.")
        sents = S.parse(text)
        overview, points = S.load("textrank-tfidf")(text, sents)
        self.assertTrue(overview)
        self.assertEqual(S.actions(sents), [("", "send the notes", "tomorrow")])
        self.assertIn("- send the notes (due tomorrow)", S.render(overview, points, [], S.actions(sents)))


class Ranking(unittest.TestCase):
    def test_word_in_every_sentence_carries_no_weight(self):
        m = S.tfidf(["the release slips", "the crash is fixed"])
        vocab = sorted({"the", "release", "slips", "crash", "is", "fixed"})
        self.assertEqual(list(m[:, vocab.index("the")]), [0, 0])
        self.assertGreater(m[0, vocab.index("release")], 0)

    def test_central_sentence_outranks_the_outlier(self):
        texts = ["the release moves to tuesday", "release tuesday needs qa", "qa runs before the tuesday release", "my cat likes fish"]
        r = S.textrank(S.tfidf(texts))
        self.assertEqual(min(range(4), key=lambda i: r[i]), 3)
        self.assertLess(r[3], r[0])


def fixture(path):
    text = open(path).read()
    return text, S.parse(text)


class AmiActionScoring(unittest.TestCase):
    # The real-data action-item number depends on reading the owner off the AMI summary sentence correctly.
    def test_owner_comes_from_the_subject_only(self):
        self.assertEqual(E.owners("The ID and UI will build a prototype out of clay."), {"Industrial Designer", "User Interface"})
        self.assertEqual(E.owners("The marketing expert will do the user requirements."), {"Marketing"})
        self.assertEqual(E.owners("The team will decide how the user interface will work"), set())

    def test_match_needs_owner_and_task(self):
        gold = "The project manager will type up the minutes of the current meeting and e-mail those to the team members."
        self.assertTrue(E.matches(gold, ("Project Manager", "type up mi minutes and probably email those out to all of you", "")))
        self.assertFalse(E.matches(gold, ("Marketing", "type up the minutes and email those out", "")))
        self.assertFalse(E.matches(gold, ("Project Manager", "just bring that up and show you all", "")))

    def test_transcript_drops_corpus_markup(self):
        text = E.transcript([{"speaker": "Project Manager", "content": "{vocalsound} Okay , I'll send the minutes ."}])
        self.assertEqual(text, "Project Manager: Okay, I'll send the minutes.")


if __name__ == "__main__":
    unittest.main()
