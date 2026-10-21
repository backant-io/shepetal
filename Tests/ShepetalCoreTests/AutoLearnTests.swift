import XCTest
@testable import ShepetalCore

/// F26: what a fix of a pasted dictation teaches. A learned pair rewrites every later dictation, so the tests that
/// matter most are the ones where nothing may be learned.
final class AutoLearnTests: XCTestCase {
    func pair(_ heard: String, _ corrected: String) -> AutoLearn.Pair { AutoLearn.Pair(heard: heard, corrected: corrected) }

    func testTypoFixIsLearned() {
        XCTAssertEqual(AutoLearn.learn(pasted: "Send it to jon by Friday.", edited: "Send it to John by Friday."), [pair("jon", "John")])
        XCTAssertEqual(AutoLearn.learn(pasted: "Ask Wisper about it", edited: "Ask Whisper about it"), [pair("Wisper", "Whisper")])
        XCTAssertEqual(pair("jon", "John").entry, Vocabulary.Entry(spoken: "jon", written: "John"))
    }

    func testPhraseFixIsLearnedAsOnePair() {
        XCTAssertEqual(AutoLearn.learn(pasted: "Deploy it to cooper netties today.", edited: "Deploy it to Kubernetes today."),
                       [pair("cooper netties", "Kubernetes")])
        XCTAssertEqual(AutoLearn.learn(pasted: "I love she petal so much", edited: "I love shepetal so much"), [pair("she petal", "shepetal")])
    }

    func testCaseFixIsLearnedAsACasingEntry() {
        let github = AutoLearn.learn(pasted: "Push it to github today.", edited: "Push it to GitHub today.")
        XCTAssertEqual(github, [pair("github", "GitHub")])
        XCTAssertEqual(github.first?.entry, Vocabulary.Entry(spoken: "GitHub", written: "GitHub"), "a casing entry, not a replacement")
        XCTAssertEqual(AutoLearn.learn(pasted: "Iphone battery", edited: "iPhone battery"), [pair("Iphone", "iPhone")])
        XCTAssertEqual(AutoLearn.learn(pasted: "Call pavel tomorrow", edited: "Call Pavel tomorrow"), [pair("pavel", "Pavel")],
                       "a capital on a name inside a sentence")
        // Style, not hearing: a capital at a sentence start, or a word made lowercase.
        XCTAssertEqual(AutoLearn.learn(pasted: "great, see you there", edited: "Great, see you there"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "Done. great work", edited: "Done. Great work"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "great work", edited: "Great work", before: "Done. "), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "Meet the Team now", edited: "Meet the team now"), [])
    }

    func testRewriteLearnsNothing() {
        XCTAssertEqual(AutoLearn.learn(pasted: "Can you send me the report today", edited: "Please share the slides with me"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "send the report", edited: "share the report"), [], "a different word, not a mishearing")
        XCTAssertEqual(AutoLearn.learn(pasted: "my cat is here", edited: "my dog is here"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "ping jon and mike today", edited: "tell John or Mikey today"), [],
                       "more than half of the words changed, even if two of them look like fixes")
    }

    func testStopwordsNumbersAndSingleCJKCharactersLearnNothing() {
        XCTAssertEqual(AutoLearn.learn(pasted: "put it over their", edited: "put it over there"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "your welcome", edited: "you're welcome"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "meet at 3 today", edited: "meet at 4 today"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "buy two apples", edited: "buy 2 apples"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "room b2b please", edited: "room B2C please"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "東 station now", edited: "京 station now"), [])
    }

    func testUntouchedTextLearnsNothing() {
        XCTAssertEqual(AutoLearn.learn(pasted: "Send it to jon.", edited: "Send it to jon."), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "Send it to jon.", edited: "Send it to jon!"), [], "punctuation is not a word")
        XCTAssertEqual(AutoLearn.learn(pasted: "Send it to jon.", edited: "Send  it to\njon."), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "", edited: "anything"), [])
    }

    func testPureDeletionAndInsertionLearnNothing() {
        XCTAssertEqual(AutoLearn.learn(pasted: "Send it really soon to Anna", edited: "Send it soon to Anna"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "Send it soon to Anna", edited: "Send it very soon to Anna"), [])
    }

    func testTextTypedAfterOrBeforeTheSpanIsIgnored() {
        XCTAssertEqual(AutoLearn.learn(pasted: "Meet jon", edited: "Meet jon tomorrow at noon, ok?"), [])
        XCTAssertEqual(AutoLearn.learn(pasted: "Meet jon", edited: "Meet John tomorrow at noon, ok?"), [pair("jon", "John")],
                       "the typed words neither count as a rewrite nor join the fix")
        XCTAssertEqual(AutoLearn.learn(pasted: "meet jon", edited: "Hi everyone, please meet John"), [pair("jon", "John")])
    }

    func testAWordLeftUnfixedElsewhereLearnsNothing() {
        XCTAssertEqual(AutoLearn.learn(pasted: "jon said jon is late", edited: "John said jon is late"), [])
    }

    func testPairsAreCappedPerDictation() {
        let pasted = "ask jon and mikel and sarra and pieter about the plan for the launch next week please"
        let edited = "ask John and Mikael and Sarah and Pieterr about the plan for the launch next week please"
        XCTAssertEqual(AutoLearn.learn(pasted: pasted, edited: edited),
                       [pair("jon", "John"), pair("mikel", "Mikael"), pair("sarra", "Sarah")])
        XCTAssertEqual(AutoLearn.maxPairs, 3)
    }

    func testSpanIsFoundInsideTheSurroundingText() {
        let before = "Dear team,\n", after = "\nBest, Anna"
        XCTAssertEqual(AutoLearn.span(in: "Dear team,\nSee you Monday.\nBest, Anna", before: before, after: after), "See you Monday.")
        XCTAssertEqual(AutoLearn.span(in: "Dear team,\n\nBest, Anna", before: before, after: after), "", "the span was deleted")
        XCTAssertEqual(AutoLearn.span(in: "Hi 👋🏽 jon", before: "Hi 👋🏽 ", after: ""), "jon")
        XCTAssertNil(AutoLearn.span(in: "Dear all,\nSee you Monday.\nBest, Anna", before: before, after: after), "edited before the span")
        XCTAssertNil(AutoLearn.span(in: "Dear team,\nSee you Monday.\nCheers", before: before, after: after), "edited after the span")
        XCTAssertNil(AutoLearn.span(in: "", before: before, after: after), "the message was sent and the field emptied")
        XCTAssertNil(AutoLearn.span(in: "abab", before: "aba", after: "bab"), "before and after cannot overlap")
    }
}
