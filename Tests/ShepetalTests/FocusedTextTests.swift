import XCTest
@testable import Shepetal
import ShepetalCore

/// The pure half of the Accessibility read. No AX call is made: the field's text and selection are given.
final class FocusedTextTests: XCTestCase {
    func testSplitsAtTheCursorAndSelection() {
        XCTAssertTrue(FocusedText.split("Please", NSRange(location: 6, length: 0)) == ("Please", ""))
        XCTAssertTrue(FocusedText.split("Send the draft today.", NSRange(location: 9, length: 5)) == ("Send the ", " today."))
        XCTAssertEqual(FocusedText.selection("Send the draft today.", NSRange(location: 9, length: 5)), "draft")
    }

    // A range outside the text is stale or wrong. Guessing the cursor from it (the old clamp put it at the end)
    // would change the case and punctuation on a guess, so it counts as unreadable: no context, no selection.
    func testRangeOutsideTheTextGivesNoContext() {
        for r in [NSRange(location: 40, length: 0), NSRange(location: 3, length: 9), NSRange(location: NSNotFound, length: 0),
                  NSRange(location: -1, length: 0)] {
            XCTAssertTrue(FocusedText.split("Please", r) == ("", ""), "\(r)")
            XCTAssertEqual(FocusedText.selection("Please", r), "", "\(r)")
        }
    }

    // An unreadable field (no AX, no text value, a bad range) reads as empty, and gets the text exactly as
    // dictated: no space, case or period guessed.
    func testUnreadableFieldInsertsTextAsDictated() {
        let (before, after) = FocusedText.split("Please", NSRange(location: 40, length: 0))
        XCTAssertEqual(InsertionRules.fit("Send the report today.", before: before, after: after,
                                          selected: FocusedText.selection("Please", NSRange(location: 40, length: 0))),
                       "Send the report today.")
    }
}
