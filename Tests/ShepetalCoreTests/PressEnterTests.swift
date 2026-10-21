import XCTest
@testable import ShepetalCore

/// F42: "press enter" at the end of a dictation is a command, not text. Anywhere else it is what the user said,
/// so it must never press Return on a sentence that only mentions it.
final class PressEnterTests: XCTestCase {
    func split(_ text: String, raw: String = "") -> (String, Bool) {
        let r = PressEnter.split(text, raw: raw)
        return (r.text, r.enter)
    }

    // However the speech model and cleanup spell it, the phrase goes and Return follows.
    func testTrailingPhraseIsStrippedInEverySpelling() {
        XCTAssertEqual(split("see you soon press enter").0, "see you soon")
        XCTAssertEqual(split("See you soon. Press Enter.").0, "See you soon.")
        XCTAssertEqual(split("See you soon PRESS ENTER!").0, "See you soon!")
        XCTAssertEqual(split("See you soon press   enter  \n").0, "See you soon")
        XCTAssertTrue(split("See you soon press enter").1)
    }

    // Cleanup puts a comma before the phrase and a period after it; the message keeps the period, not the comma.
    func testCommaBeforeThePhraseGoesAndItsSentenceEndStays() {
        XCTAssertEqual(split("See you soon, press enter.").0, "See you soon.")
        XCTAssertEqual(split("Ship it; press enter").0, "Ship it")
        XCTAssertEqual(split("Okay? Press enter.").0, "Okay?", "the text's own sentence end wins")
    }

    // "Press enter to continue" is an instruction the user is writing down, not a command.
    func testPhraseInsideTheTextIsLeftAlone() {
        for text in ["Press enter to continue.", "I said press enter twice and it worked.", "We impress enter", "press entering"] {
            XCTAssertEqual(split(text).0, text)
            XCTAssertFalse(split(text).1, text)
        }
    }

    // The cleanup model can drop the phrase as an instruction; the raw transcript still says it (as in Wispr).
    func testRawTranscriptEndingWithThePhraseStillPressesReturn() {
        XCTAssertEqual(split("See you soon.", raw: "see you soon press enter").0, "See you soon.")
        XCTAssertTrue(split("See you soon.", raw: "see you soon press enter").1)
        XCTAssertFalse(split("See you soon.", raw: "press enter to see you soon").1, "only a trailing phrase counts")
        XCTAssertFalse(split("See you soon.", raw: "See you soon.").1)
    }

    // A dictation of only the phrase leaves nothing to paste; the pipeline then shows `nothingToSend`.
    func testPhraseAloneLeavesAnEmptyText() {
        XCTAssertEqual(split("Press enter.").0, "")
        XCTAssertTrue(split("Press enter.").1)
        XCTAssertEqual(split(", press enter").0, "")
    }
}
