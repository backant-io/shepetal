import XCTest
@testable import ShepetalCore

/// The paste goes to the field the user was in when dictation started (insertion-context.md 2.2).
final class FocusPlanTests: XCTestCase {
    func testSameAppAndElementDoesNothing() {
        XCTAssertEqual(FocusPlan.decide(appRunning: true, appIsFront: true, elementAlive: true, elementIsFocused: true), .none)
    }

    // The user clicked into another app, or another field of the same app, while speaking.
    func testOtherAppActivatesAndFocuses() {
        XCTAssertEqual(FocusPlan.decide(appRunning: true, appIsFront: false, elementAlive: true, elementIsFocused: false), .activateAndFocus)
        XCTAssertEqual(FocusPlan.decide(appRunning: true, appIsFront: true, elementAlive: true, elementIsFocused: false), .activateAndFocus)
    }

    // The field closed (a sheet or a tab went away): the app still gets the text.
    func testElementGoneActivatesAppOnly() {
        XCTAssertEqual(FocusPlan.decide(appRunning: true, appIsFront: false, elementAlive: false, elementIsFocused: false), .activateApp)
        XCTAssertEqual(FocusPlan.decide(appRunning: true, appIsFront: true, elementAlive: false, elementIsFocused: false), .none)
    }

    // Nothing to go back to: paste where focus is now, as before focus restore existed.
    func testAppQuitPastesInPlace() {
        XCTAssertEqual(FocusPlan.decide(appRunning: false, appIsFront: false, elementAlive: false, elementIsFocused: false), .pasteInPlace)
        XCTAssertEqual(FocusPlan.decide(appRunning: false, appIsFront: false, elementAlive: true, elementIsFocused: false), .pasteInPlace)
    }
}
