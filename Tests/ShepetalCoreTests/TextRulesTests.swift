import XCTest
@testable import ShepetalCore

final class InsertionRulesTests: XCTestCase {
    func fit(_ s: String, _ before: String, _ after: String) -> String { InsertionRules.fit(s, before: before, after: after) }

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

    func testFollowingTextDropsSentenceEndAndAddsSpace() {
        XCTAssertEqual(fit("The report.", "", "is due"), "The report ")
        XCTAssertEqual(fit("The report.", "", ", which"), "The report")
        XCTAssertEqual(fit("Done.", "", "Next sentence."), "Done. ")
    }

    func testNoSpaceAfterOpeningBracket() {
        XCTAssertEqual(fit("Maybe.", "(", ")"), "maybe.")
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
        XCTAssertEqual(Cleanup.apply("Um, so the the build is, uh, green."), "So the build is, green.")
        XCTAssertEqual(Cleanup.apply("  We ship   today .  "), "We ship today.")
    }

    func testKeepsWordsThatContainFillers() {
        XCTAssertEqual(Cleanup.apply("Hummus and umbrellas."), "Hummus and umbrellas.")
    }
}
