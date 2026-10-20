"""Run from summarize/: .venv/bin/python -m unittest -v"""
import glob, json, math, os, re, sys, unittest
from collections import Counter
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import summarize as S
import eval_qmsum as E
import ami_actions as A


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
                self.assertEqual(md, read(os.path.join(HERE, "out", "textrank-tfidf", os.path.basename(path)[:-4] + ".md")))

    def test_fixture_action_items_keep_owner_and_due(self):
        # Goal: action items are recovered with the right owner; the due date is what makes them schedulable.
        for path in sorted(glob.glob(os.path.join(HERE, "fixtures", "*.txt"))):
            _, sents = fixture(path)
            got = [(o, d) for o, _, d in S.actions(sents)]
            ref = re.findall(r"^- (\w+): .*?(?:\(due ([^)]+)\))?\.?$", read(path[:-4] + ".ref.md").split("## Action items")[1], re.M)
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


def read(path):
    with open(path) as f:
        return f.read()


def fixture(path):
    text = read(path)
    return text, S.parse(text)


MEETING = [("Ana", "Okay, let's get started."), ("Ben", "Sure."), ("Cy", "I'll go first with the budget numbers."),
           ("Cy", "We spent about half of the money on parts."), ("Ben", "That sounds fine to me."),
           ("Ana", "Good. The next meeting is in thirty minutes."),
           ("Ana", "Ben, for the next meeting you're going to work on the battery design."), ("Ben", "Okay."),
           ("Ana", "And Cy, you'll look at what the competitors charge."), ("Cy", "Will do."), ("Ana", "Thanks everyone.")]
TINY = {"bias": -2.0, "threshold": 0.5, "weights": {"u:homework": 4.0}}  # flags any sentence with "homework"


class ActionClassifier(unittest.TestCase):
    # Goal rule 6 / issue #18: action items come from the AMI-trained linear model, not from "I'll" alone.
    def test_shipped_model_finds_assigned_tasks_and_skips_meeting_moves(self):
        # In real meetings most tasks are handed out ("Ben, you're going to ..."); "I'll go first" is not a task.
        got = S.actions(MEETING)
        self.assertEqual([(o, t[:20]) for o, t, _ in got], [("Ben", "Ben, for the next me"), ("Cy", "Cy, you'll look at w")])

    def test_score_is_sigmoid_of_bias_plus_feature_weights(self):
        p = S.action_scores([("A", "homework for you"), ("B", "nice weather")], TINY)
        self.assertAlmostEqual(p[0], 1 / (1 + math.exp(-2.0)))
        self.assertAlmostEqual(p[1], 1 / (1 + math.exp(2.0)))

    def test_classifier_hit_needs_no_first_person(self):
        sents = [("Ana", "Ben, the homework is the battery design."), ("Ben", "Sure.")]
        self.assertEqual(S.actions(sents, TINY), [("Ben", "Ben, the homework is the battery design", "")])

    def test_dated_first_person_commitment_survives_a_low_score(self):
        # The model rarely saw clean "I'll X by Friday" lines in AMI; the old rule keeps them when a date is given.
        never = {**TINY, "bias": -20.0}
        self.assertEqual(S.actions([("Tom", "I'll send the notes by Friday.")], never), [("Tom", "send the notes", "Friday")])
        self.assertEqual(S.actions([("Tom", "I'll go first.")], never), [])

    def test_deadline_prefers_the_by_date(self):
        got = S.actions([("Maya", "I will follow up with Leo today and get the copy by Friday.")], TINY)
        self.assertEqual(got, [("Maya", "follow up with Leo today and get the copy", "Friday")])

    def test_repeated_task_keeps_the_later_mention(self):
        sents = [("Ana", "Ben, homework: fix the battery."), ("Ben", "Okay."), ("Ana", "So Ben, homework: fix the battery today.")]
        self.assertEqual([i for i, *_ in S.action_items(sents, TINY)], [2])

    def test_two_tasks_said_the_same_way_are_both_kept(self):
        # A hand-out reads "you have to work on X, you have to work on Y". Compared on all words, Y used to replace X:
        # on AMI train + dev that dropped 5 of 187 owned items. Only content words decide that a task was repeated.
        work = {"bias": -2.0, "threshold": 0.5, "weights": {"u:work": 4.0}}
        sents = [("Ana", "You have to work on the components concept."), ("Ana", "You have to work on the user interface."),
                 ("Ben", "Okay.")]
        self.assertEqual([i for i, *_ in S.action_items(sents, work)], [0, 1])
        self.assertTrue(S.same_task("ask Leo to send the revised copy", "follow up with Leo today and get the revised copy"))

    def test_a_request_asked_as_a_question_is_an_action_item(self):
        slides = {"bias": -2.0, "threshold": 0.5, "weights": {"u:slides": 4.0}}
        self.assertEqual(S.actions([("Ana", "Could you e-mail me the slides?"), ("Ben", "Sure.")], slides),
                         [("Ben", "Could you e-mail me the slides?", "")])
        self.assertEqual(S.actions([("Ana", "Did you see the slides?"), ("Ben", "Yes.")], slides), [])

    def test_modal_cues_are_features_the_shipped_model_relies_on(self):
        # "you'll", "I'm going to", "Kate will": the hand-off cues that word pairs only learn one spelling at a time.
        f = S.action_features([("Ana", "So Kate will draft it and you'll check it."), ("Ben", "This will take a week."),
                               ("Cy", "I'm going to send it after the next meeting.")])
        self.assertTrue({"a:name", "a:you"} <= f[0])
        self.assertNotIn("a:name", f[1])  # a capital that only opens the sentence is no name
        self.assertTrue({"a:i", "a:next"} <= f[2])
        w = S.load_model()["weights"]
        self.assertTrue(all(w.get(k, 0) > 0.3 for k in ("a:you", "a:i", "a:name")), {k: w.get(k) for k in ("a:you", "a:i", "a:name")})

    def test_shipped_model_is_plain_json_a_port_can_read(self):
        # The Swift port (Sources/ShepetalSummary) sums these weights itself: no runtime, no pickles, a few hundred KB.
        with open(S.MODEL) as fh:
            m = json.load(fh)
        self.assertEqual(set(m), {"bias", "threshold", "weights", "C", "trained_on"})
        self.assertTrue(all(isinstance(v, float) for v in m["weights"].values()))
        self.assertLess(os.path.getsize(S.MODEL), 1 << 20)

    def test_missing_model_fails_loudly(self):
        with patch.dict(S._model, clear=True):
            with self.assertRaises(FileNotFoundError):
                S.load_model(os.path.join(HERE, "no-such-model.json"))


class OwnerRules(unittest.TestCase):
    # "Recovered with the right owner" is half of the goal's number; these are the rules that pick the owner.
    def owner(self, sents, i=0):
        return S.owner(sents, i, S.aliases(sents))

    def test_named_participant_owns_it(self):
        # Cy answers first, but the task was handed to Ben by name.
        self.assertEqual(self.owner([("Ana", "Ben, you'll take the battery design."), ("Cy", "Okay."), ("Ben", "Sure.")]), "Ben")

    def test_first_person_owns_it_even_when_someone_else_is_named(self):
        self.assertEqual(self.owner([("Kenji", "I'll send the list to Daniel."), ("Daniel", "Thanks.")]), "Kenji")

    def test_asking_someone_hands_it_to_them(self):
        self.assertEqual(self.owner([("Ana", "I'll ask Ben to check the costs."), ("Ben", "Sure.")]), "Ben")

    def test_you_goes_to_whoever_answers(self):
        sents = [("Ben", "Fine."), ("Ana", "You can look at the costs."), ("Ana", "It matters."), ("Cy", "Will do.")]
        self.assertEqual(self.owner(sents, 1), "Cy")

    def test_you_goes_to_whoever_answers_after_a_long_hand_out(self):
        # The chair often talks on for a while before the addressee says "okay"; a 3-sentence window handed it to Ben.
        sents = [("Ben", "Fine."), ("Ana", "You'll look at the costs."), *[("Ana", "And more on that.")] * 5, ("Cy", "Will do.")]
        self.assertEqual(self.owner(sents, 1), "Cy")

    def test_job_title_said_about_oneself_names_the_speaker(self):
        # Without calendar names the labels say nothing; "I'm the Industrial Designer" ties the title to a voice.
        sents = [("Speaker 1", "I'm the uh Industrial Designer on this project."), ("Speaker 2", "And I'm the User Interface Designer."),
                 ("Speaker 3", "So the Industrial Designer will build the case."), ("Speaker 2", "Okay.")]
        self.assertEqual(self.owner(sents, 2), "Speaker 1")
        al = S.aliases(sents)
        self.assertEqual((al["ID"], al["UID"], al["Interface"]), ("Speaker 1", "Speaker 2", "Speaker 2"))
        self.assertNotIn("Designer", al)  # both are designers, so the bare word names neither

    def test_you_with_no_answer_goes_to_the_previous_speaker(self):
        self.assertEqual(self.owner([("Ben", "What should I do?"), ("Ana", "You can look at the costs.")], 1), "Ben")

    def test_role_label_and_its_initials_name_the_owner(self):
        sents = [("Project Manager", "The ID is going to work on the components."), ("Marketing", "Right."), ("Industrial Designer", "Ok.")]
        self.assertEqual(self.owner(sents), "Industrial Designer")

    def test_self_introduced_name_maps_to_its_speaker(self):
        sents = [("Speaker 2", "Hi, I'm Kate."), ("Speaker 1", "Kate will draft the plan."), ("Speaker 3", "Okay.")]
        self.assertEqual(self.owner(sents, 1), "Speaker 2")

    # Calendar names (goal rule 7) are real names, and many names or their initials are also common words.
    def test_initials_count_only_in_capitals(self):
        # "it is", "look at", "go to": the task goes to whoever answers, not to Ian Smith, Amy Thompson or Tom Owens.
        for third in ("Ian Smith", "Amy Thompson", "Tom Owens"):
            sents = [("Ana Lopez", "You need to check what it is going to cost and look at it."), ("Ben Cole", "Okay."), (third, "Hm.")]
            self.assertEqual(self.owner(sents), "Ben Cole", third)

    def test_name_that_is_a_word_counts_only_capitalized(self):
        self.assertEqual(self.owner([("Ana", "You will send the deck to legal."), ("Ben", "Okay."), ("Will", "Hm.")]), "Ben")
        self.assertEqual(self.owner([("Ana", "You will send the deck to legal."), ("Ben", "Okay."), ("will", "Hm.")]), "Ben")
        self.assertEqual(self.owner([("Ana", "Will, you send the deck to legal."), ("Ben", "Okay."), ("Will", "Hm.")]), "Will")

    def test_day_or_possessive_after_this_is_is_no_name(self):
        sents = [("Speaker 1", "Hi."), ("Speaker 2", "This is Friday's plan."),
                 ("Speaker 1", "Friday works, you can send the draft."), ("Speaker 3", "Sure.")]
        self.assertEqual(self.owner(sents, 2), "Speaker 3")
        sents[1] = ("Speaker 2", "This is Friday, the last day.")
        self.assertEqual(self.owner(sents, 2), "Speaker 3")
        sents[1] = ("Speaker 2", "This is Kate's plan.")
        self.assertNotIn("Kate", S.aliases(sents))

    def test_undiarized_transcript_has_no_owner(self):
        self.assertEqual(self.owner([("", "You will send it tomorrow.")]), "")


class AmiLabels(unittest.TestCase):
    def test_owner_comes_from_the_subject_only(self):
        # Gold owners are read off the AMI summary sentence; a role named later in the sentence is not the owner.
        self.assertEqual(A.owners("The ID and UI will build a prototype out of clay."), {"Industrial Designer", "User Interface"})
        self.assertEqual(A.owners("The marketing expert will do the user requirements."), {"Marketing"})
        self.assertEqual(A.owners("The team will decide how the user interface will work"), set())

    def test_transcript_drops_corpus_markup(self):
        text = E.transcript([{"speaker": "Project Manager", "content": "{vocalsound} Okay , I'll send the minutes ."}])
        self.assertEqual(text, "Project Manager: Okay, I'll send the minutes.")


@unittest.skipUnless(os.path.isdir(os.path.join(A.AMI, "words")), "AMI annotations not in .cache/ami (see ami_actions.py)")
class AmiTestSplit(unittest.TestCase):
    # The number in docs/summarization.md. It needs the AMI annotations, which stay out of the repo.
    def test_split_comes_from_the_corpus_metadata(self):
        sp = A.splits()
        self.assertEqual(Counter(sp.values()), {"train": 98, "dev": 20, "test": 20})
        self.assertEqual({m[:-1] for m, s in sp.items() if s == "test"}, {"ES2004", "ES2014", "IS1009", "TS3003", "TS3007"})

    def test_training_and_threshold_never_see_the_test_split(self):
        fold = A.folds()
        test = {m for m, s in A.splits().items() if s == "test"}
        self.assertEqual(len(fold), 118)
        self.assertFalse(test & fold.keys())
        self.assertTrue(all(len({fold[x] for x in fold if x[:-1] == m[:-1]}) == 1 for m in fold))  # a series stays in one fold

    def test_recall_with_right_owner_on_the_test_split(self):
        # Role labels are the best case: AMI speakers say the roles aloud, the way people would say calendar names.
        r = A.score("test", S.load_model())
        self.assertEqual(r["owned"], 20)
        self.assertGreaterEqual(r["hit"], 16)  # 80% (was 65%); 5-fold CV on train + dev says 54.5%, so 20 items flatter it
        # Recall must not come from flooding the section. The 8-item cap is applied in CV, where the threshold is picked
        # (7.8 per meeting); the test split came out at 8.4. Precision is pinned at the old 19%.
        self.assertLessEqual(r["pred"], 8.5 * r["meetings"])
        self.assertGreaterEqual(r["tp"] / r["pred"], 0.19)

    def test_recall_with_diarization_labels_on_the_test_split(self):
        # What the app has without calendar names: nobody says "Speaker 2", so owners come from turn-taking and from
        # titles or names people give themselves ("I'm the Industrial Designer").
        r = A.score("test", S.load_model(), labels=A.SPEAKERS)
        self.assertGreaterEqual(r["hit"], 14)  # 70% (was 40%); CV says 46.5%
        self.assertLessEqual(r["pred"], 8.5 * r["meetings"])

    def test_relabelling_hides_the_roles_and_maps_owners_back(self):
        seen = set()
        def speaker_rule(sents):
            seen.update(spk for spk, _ in sents)
            return [(i, spk) for i, (spk, _) in enumerate(sents)]
        a = A.score("test", None, rule=speaker_rule, labels=A.SPEAKERS)
        self.assertEqual(seen, set(A.SPEAKERS))  # the summarizer never sees a role
        b = A.score("test", None, rule=speaker_rule)
        self.assertGreater(b["hit"], 0)
        self.assertEqual((a["found"], a["hit"]), (b["found"], b["hit"]))

    def test_names_nobody_says_change_no_owner(self):
        # Their initials and words are common English ("is", "at", "to", "will"); as unspoken names they must act like
        # "Speaker 1..4". Before owners were matched as written, they scored 5/20 against 8/20.
        keys = ["owned", "hit", "found", "pred", "tp"]
        names = A.score("test", S.load_model(), labels=["Ian Smith", "Amy Thompson", "Tom Owens", "Will Fern"])
        plain = A.score("test", S.load_model(), labels=A.SPEAKERS)
        self.assertEqual([names[k] for k in keys], [plain[k] for k in keys])

    def test_recall_counts_only_the_right_owner(self):
        # Flagging every dialogue act finds every item, but with a wrong owner it must score zero.
        r = A.score("test", None, rule=lambda sents: [(i, "Nobody") for i in range(len(sents))])
        self.assertEqual((r["found"], r["hit"]), (20, 0))


if __name__ == "__main__":
    unittest.main()
