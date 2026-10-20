"""Run from summarize/: .venv/bin/python -m unittest -v"""
import os, sys, unittest
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
