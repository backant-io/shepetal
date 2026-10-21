import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F42 on the inserter: Return follows the text only once it landed in the window that kept focus (rule 8). A
/// Return anywhere else would send a half message or run a terminal line in the wrong window.
/// A private pasteboard and captured events: nothing is posted to the system.
@MainActor
final class PressReturnTests: XCTestCase {
    var pasteboard: NSPasteboard!
    var events: [CGEvent] = []
    var returns: Int { events.filter { $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 36 }.count }

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
        events = []
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    /// The app under the cursor reads the paste at ⌘V.
    func insert(_ mode: PasteMode = .local, read: Bool = true, stillFocused: @escaping () -> Bool = { true },
                pressReturn: Bool = true, onReturn: @escaping () -> Void = {}) async -> Inserter.Result {
        let pb = pasteboard!
        return await Inserter(pasteboard: pasteboard).insert("See you soon.", mode: mode, sendPaste: { [unowned self] e in
            let code = e.getIntegerValueField(.keyboardEventKeycode)
            if e.type == .keyDown, code == 36 { onReturn() } else if e.type == .keyDown, read { _ = pb.string(forType: .string) }
            events.append(e)
        }, stillFocused: stillFocused, pressReturn: pressReturn)
    }

    // The message is sent: one Return, after the paste, once the field has had the restore wait to take the text.
    func testLandedPasteIsFollowedByExactlyOneReturn() async {
        var clipboardAtReturn: String?
        let r = await insert(onReturn: { [unowned self] in clipboardAtReturn = pasteboard.string(forType: .string) })
        XCTAssertTrue(r.landed)
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [Int64(Inserter.vKeyCode()), Int64(Inserter.vKeyCode()), 36, 36], "⌘V down and up, then Return down and up")
        XCTAssertEqual(clipboardAtReturn, "earlier", "Return comes after the restore wait")
    }

    // A held fn or Shift must not turn Return into Enter or a line break.
    func testReturnHasNoModifier() {
        let e = Inserter.returnKey()
        XCTAssertEqual(e.map { $0.type }, [.keyDown, .keyUp])
        for x in e {
            XCTAssertEqual(x.getIntegerValueField(.keyboardEventKeycode), 36)
            XCTAssertTrue(x.flags.isDisjoint(with: [.maskCommand, .maskShift, .maskSecondaryFn, .maskAlternate, .maskControl]))
        }
    }

    // Nobody took the paste: the text is on the clipboard for ⌘V and nothing is sent.
    func testNoReturnWhenThePasteDidNotLand() async {
        let r = await insert(read: false)
        XCTAssertFalse(r.landed)
        XCTAssertEqual(returns, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "See you soon.")
    }

    // Focus moved after the paste: the text is in the first window, and Return must not go to the new one.
    func testNoReturnWhenFocusMovedAfterThePaste() async {
        let r = await insert(stillFocused: { false })
        XCTAssertTrue(r.landed)
        XCTAssertEqual(returns, 0)
    }

    func testNoReturnWithoutTheCommand() async {
        let r = await insert(pressReturn: false)
        XCTAssertTrue(r.landed)
        XCTAssertEqual(returns, 0)
    }

    // The other modes follow the same rule: remote after the viewer's read, typed after the last key.
    func testRemoteAndTypedPressReturnOnceAfterTheText() async {
        _ = await insert(.remote)
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(events.last?.getIntegerValueField(.keyboardEventKeycode), 36)
        events = []
        _ = await insert(.typed)
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(events.suffix(2).map { $0.getIntegerValueField(.keyboardEventKeycode) }, [36, 36], "Return is the last key")
        events = []
        _ = await insert(.remote, read: false)
        XCTAssertEqual(returns, 0, "a viewer that never read gets no Return")
    }
}
