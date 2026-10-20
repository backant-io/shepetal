import XCTest
@testable import ShepetalCore

final class InsertionRulesTests: XCTestCase {
    func fit(_ s: String, _ before: String, _ after: String, selected: String = "") -> String {
        InsertionRules.fit(s, before: before, after: after, selected: selected)
    }
    let nbsp = "\u{00A0}"

    func testEmptyFieldKeepsTextAsIs() {
        XCTAssertEqual(fit("Hello there.", "", ""), "Hello there.")
    }

    func testMidSentenceLowercasesAndAddsSpace() {
        XCTAssertEqual(fit("Send it today.", "Please", ""), " send it today.")
        XCTAssertEqual(fit("Send it today.", "Please ", ""), "send it today.")
    }

    func testAfterSentenceEndKeepsCapital() {
        XCTAssertEqual(fit("Thanks.", "Done.", ""), " Thanks.")
        XCTAssertEqual(fit("Thanks.", "Line one\n", ""), "Thanks.")
    }

    func testIAndAcronymsStayCapitalized() {
        XCTAssertEqual(fit("I think so.", "and ", ""), "I think so.")
        XCTAssertEqual(fit("API keys rotate.", "the ", ""), "API keys rotate.")
    }

    // The space before following text is a non-breaking space now (see testTrailingBoundarySpaceIsNBSP).
    func testFollowingTextDropsSentenceEndAndAddsSpace() {
        XCTAssertEqual(fit("The report.", "", "is due"), "The report" + nbsp)
        XCTAssertEqual(fit("The report.", "", ", which"), "The report")
        XCTAssertEqual(fit("Done.", "", "Next sentence."), "Done." + nbsp)
    }

    // Apps that trim trailing ASCII spaces from a paste would glue our last word to the next one.
    func testTrailingBoundarySpaceIsNBSP() {
        let out = fit("Hello.", "", "world")
        XCTAssertEqual(out.unicodeScalars.last, "\u{00A0}")
        XCTAssertFalse(out.hasSuffix(" "))
    }

    func testNoTrailingSpaceWhenNothingFollows() {
        XCTAssertEqual(fit("Hello there.", "Done.", ""), " Hello there.")
        XCTAssertEqual(fit("Hello there.", "", " Next one."), "Hello there.")
        XCTAssertEqual(fit("Hello there.", "", "\nnext line"), "Hello there.")
    }

    // Only the trailing space is non-breaking. A leading NBSP would stop the line from wrapping there.
    func testLeadingSpaceStaysASCII() {
        XCTAssertEqual(fit("Send it.", "Please", ""), " send it.")
        XCTAssertEqual(fit("Send it", "Please", "now"), " send it" + nbsp)
    }

    // Replacing a selected word mid-sentence: the new words take its case.
    func testSelectionLowercaseIsMatched() {
        XCTAssertEqual(fit("Quick brown.", "The ", " fox", selected: "slow"), "quick brown")
        XCTAssertEqual(fit("quick brown", "", "", selected: "Slow"), "Quick brown")
    }

    func testSelectionWithoutPeriodDropsOurs() {
        XCTAssertEqual(fit("New text.", "", "", selected: "Old text"), "New text")
    }

    func testSelectionWithPeriodKeepsIt() {
        XCTAssertEqual(fit("New text.", "", "", selected: "Old text."), "New text.")
        XCTAssertEqual(fit("New text", "", "", selected: "Old text!"), "New text!")
        XCTAssertEqual(fit("New text?", "", "", selected: "Old text."), "New text?")
    }

    // The spaces around the selection are the user's; the paste replaces them, so they go back.
    func testSelectionKeepsItsSpaces() {
        XCTAssertEqual(fit("Bar baz.", "(", ")", selected: " Foo "), " Bar baz ")
        XCTAssertEqual(fit("Bar baz.", "a", "b", selected: " foo "), " bar baz ")
        XCTAssertEqual(fit("Bar baz.", "", "", selected: "\tfoo\n"), "\tbar baz\n")
    }

    // "I" and acronyms keep their capital, and a selected "I" or acronym says nothing about sentence position.
    func testIAndAcronymsIgnoreSelectionCase() {
        XCTAssertEqual(fit("I agree.", "", "", selected: "maybe"), "I agree")
        XCTAssertEqual(fit("API keys.", "", "", selected: "the keys"), "API keys")
        XCTAssertEqual(fit("The endpoint", "Call ", "", selected: "API"), "the endpoint")
        XCTAssertEqual(fit("Then", "", "", selected: "I"), "Then")
    }

    // Text on earlier lines says nothing about the cursor's sentence.
    func testOnlyLastLineOfBeforeCounts() {
        XCTAssertEqual(fit("Please send it.", "Hello.\nplease", ""), " please send it.")
        XCTAssertEqual(fit("Send it.", "and then\n", ""), "Send it.")
        XCTAssertEqual(fit("Send it.", "and then\r\n", ""), "Send it.")
    }

    func testOnlyFirstLineOfAfterCounts() {
        XCTAssertEqual(fit("Done.", "", "\ncontinues below"), "Done.")
    }

    func testNoSpaceAfterOpeningBracket() {
        XCTAssertEqual(fit("Maybe.", "(", ")"), "maybe.")
    }

    // M-INS-1: the model capitalises every utterance and ends it with a period. Clicked into the middle of a
    // sentence, that period would split the user's sentence in two, whatever word comes next.
    func testMidSentenceDropsPeriodBeforeAnyFollowingWord() {
        XCTAssertEqual(fit("Yesterday.", "I met ", "John today."), "yesterday" + nbsp)
        XCTAssertEqual(fit("Finally.", "Today ", "I went home."), "finally" + nbsp)
        XCTAssertEqual(fit("About.", "It took ", "5 days."), "about" + nbsp)
    }

    // The sentence already has its end right after the cursor: a second period would double it.
    func testBeforeSentenceEndDropsOurs() {
        XCTAssertEqual(fit("Today.", "I went home", "."), " today")
        XCTAssertEqual(fit("Right now!", "Do it", "!"), " right now")
    }

    // Between two sentences the dictation is a sentence of its own and keeps its capital and period.
    func testBetweenSentencesKeepsCapitalAndPeriod() {
        XCTAssertEqual(fit("Big news.", "Hello. ", "World."), "Big news." + nbsp)
        XCTAssertEqual(fit("Big news.", "", "World."), "Big news." + nbsp)
    }

    // Only the first letter is ever changed: names and acronyms the model capitalised later in the text stay.
    func testOnlyTheFirstLetterChanges() {
        XCTAssertEqual(fit("Send it to John at NASA.", "Please", ""), " send it to John at NASA.")
    }
}

final class PasteCheckTests: XCTestCase {
    func testDataRequestedAfterCmdVMeansLanded() {
        XCTAssertEqual(PasteCheck.verdict(postedAt: 10, requestedAt: 10.05, now: 10.06), .landed)
        XCTAssertEqual(PasteCheck.restoreAt(postedAt: 10, requestedAt: 10.05), 10.55, accuracy: 1e-9)
    }

    func testNoRequestWithinOneSecondMeansFailed() {
        XCTAssertEqual(PasteCheck.verdict(postedAt: 10, requestedAt: nil, now: 10.9), .waiting)
        XCTAssertEqual(PasteCheck.verdict(postedAt: 10, requestedAt: nil, now: 11.0), .failed)
        XCTAssertEqual(PasteCheck.restoreAt(postedAt: 10, requestedAt: nil), 11.0, accuracy: 1e-9)
    }

    // A clipboard manager reading before Cmd+V is not the paste landing.
    func testReadBeforeCmdVDoesNotCount() {
        XCTAssertEqual(PasteCheck.verdict(postedAt: 10, requestedAt: 9.9, now: 11.2), .failed)
    }
}

final class CleanupTests: XCTestCase {
    func testDropsFillersAndStutters() {
        XCTAssertEqual(Cleanup.apply("Um, so the the build is, uh, green."), "So the build is green.")
        XCTAssertEqual(Cleanup.apply("  We ship   today .  "), "We ship today.")
    }

    // The commas around a mid-sentence filler were the pause, not punctuation the user wanted.
    func testDropsTheCommasAroundAFiller() {
        XCTAssertEqual(Cleanup.apply("I think we should, uh, push the launch."), "I think we should push the launch.")
        XCTAssertEqual(Cleanup.apply("Send me the, um, the slides."), "Send me the slides.")
    }

    func testKeepsWordsThatContainFillers() {
        XCTAssertEqual(Cleanup.apply("Hummus and umbrellas."), "Hummus and umbrellas.")
    }

    // Some doubled words are correct English. Dropping one changes what the user said.
    func testKeepsGrammaticalRepeats() {
        XCTAssertEqual(Cleanup.apply("I had had enough, and I think that that is fine."),
                       "I had had enough, and I think that that is fine.")
        XCTAssertEqual(Cleanup.apply("It is very very good, no no."), "It is very very good, no no.")
    }

    // Repeats that are never correct English are stutters and go.
    func testDropsStuttersOnWordsThatNeverRepeat() {
        XCTAssertEqual(Cleanup.apply("I I think a a test and and the the fix work."), "I think a test and the fix work.")
    }

    // "Uh-huh" and "mm-hmm" are answers, not fillers.
    func testKeepsHyphenatedAnswers() {
        XCTAssertEqual(Cleanup.apply("Uh-huh, sounds good."), "Uh-huh, sounds good.")
        XCTAssertEqual(Cleanup.apply("Mm-hmm, ship it."), "Mm-hmm, ship it.")
    }
}
