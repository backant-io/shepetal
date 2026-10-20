import XCTest
@testable import ShepetalCore

/// Rule 8: text only goes into the window that stayed in focus; otherwise it goes to the clipboard.
/// Nothing here ever moves focus: the only outcomes are "paste" and "leave it on the clipboard".
final class PasteGateTests: XCTestCase {
    typealias Focus = (app: Int32, window: String?)

    func testSameWindowPastes() {
        XCTAssertEqual(PasteGate.focusKept(start: (1, "doc"), now: (1, "doc") as Focus), true)
        XCTAssertNil(PasteGate.blocked(focusKept: true, secureInputApp: nil))
    }

    // The user clicked into another app, or another window of the same app, while speaking.
    func testOtherAppOrWindowGoesToTheClipboard() {
        XCTAssertEqual(PasteGate.focusKept(start: (1, "doc"), now: (2, "note") as Focus), false)
        XCTAssertEqual(PasteGate.focusKept(start: (1, "doc"), now: (1, "other doc") as Focus), false)
        // Another app is enough to know focus moved, even when a window cannot be read.
        XCTAssertEqual(PasteGate.focusKept(start: (1, nil), now: (2, nil) as Focus), false)
        XCTAssertEqual(PasteGate.blocked(focusKept: false, secureInputApp: nil),
                       "The window changed while you spoke. The text is on the clipboard: press ⌘V to paste it.")
    }

    // A window that cannot be read still records the app: focus moving to another app whose window is
    // unreadable (busy, or no AX window) must go to the clipboard, not count as "unknown".
    func testUnreadableWindowStillRecordsTheApp() {
        let start = PasteGate.focus(axPid: 1, frontmostPid: 1, window: "doc")
        let now = PasteGate.focus(axPid: 2, frontmostPid: 2, window: nil as String?)
        XCTAssertEqual(now?.app, 2)
        XCTAssertEqual(PasteGate.focusKept(start: start, now: now), false)
        // No AX answer at all (no Accessibility, or the pid read failed): the frontmost app, no window.
        let fallback = PasteGate.focus(axPid: nil, frontmostPid: 3, window: "ignored")
        XCTAssertEqual(fallback?.app, 3)
        XCTAssertNil(fallback?.window)
        XCTAssertEqual(PasteGate.focusKept(start: start, now: fallback), false)
        XCTAssertNil(PasteGate.focus(axPid: nil, frontmostPid: nil, window: "doc"))
    }

    // Without Accessibility the window cannot be read: paste, and let the paste check catch a miss.
    func testUnreadableFocusPastes() {
        XCTAssertNil(PasteGate.focusKept(start: (1, nil), now: (1, nil) as Focus))
        XCTAssertNil(PasteGate.focusKept(start: (1, "doc"), now: (1, nil) as Focus))
        XCTAssertNil(PasteGate.focusKept(start: nil, now: (1, "doc") as Focus))
        XCTAssertNil(PasteGate.focusKept(start: (1, "doc"), now: nil as Focus?))
        XCTAssertNil(PasteGate.blocked(focusKept: nil, secureInputApp: nil))
    }

    // Secure input stops the synthesized Cmd+V; the user's own ⌘V still works.
    func testSecureInputGoesToTheClipboard() {
        XCTAssertEqual(PasteGate.blocked(focusKept: true, secureInputApp: "Terminal"),
                       "Secure input is on in Terminal. The text is on the clipboard: press ⌘V to paste it.")
        XCTAssertEqual(PasteGate.blocked(focusKept: nil, secureInputApp: "Terminal"), PasteGate.secureInput("Terminal"))
        XCTAssertEqual(PasteGate.blocked(focusKept: false, secureInputApp: "Terminal"), PasteGate.focusMoved)
    }

    // Every way the text ends up on the clipboard tells the user to press ⌘V.
    func testEveryClipboardMessageSaysPressCmdV() {
        for m in [PasteGate.focusMoved, PasteGate.notLanded, PasteGate.secureInput("another app")] {
            XCTAssertTrue(m.hasSuffix("The text is on the clipboard: press ⌘V to paste it."), m)
        }
    }
}
