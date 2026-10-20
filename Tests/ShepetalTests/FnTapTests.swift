import CoreGraphics
import XCTest
@testable import Shepetal

/// The tap's event handling without a real tap. macOS turns a slow tap off and drops the events in between,
/// so an fn key-up can be lost; if fn is no longer held when the tap comes back, the hold must end,
/// or the recording would run until the next fn press.
final class FnTapTests: XCTestCase {
    var held = true
    var changes: [Bool] = []
    var otherKeys = 0
    var tap: FnTap!

    override func setUp() {
        tap = FnTap(fnHeld: { [unowned self] in self.held })
        tap.onChange = { [unowned self] down, _ in self.changes.append(down) }
        tap.onOtherKey = { [unowned self] _ in self.otherKeys += 1 }
    }

    func key(_ code: Int64, fn: Bool = false) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        e.flags = fn ? .maskSecondaryFn : []
        return e
    }

    func fnDown() { tap.handle(.flagsChanged, key(63, fn: true)) }
    func fnUp() { tap.handle(.flagsChanged, key(63)) }
    func disabled(_ type: CGEventType) { tap.handle(type, CGEvent(source: nil)!) }

    func testTapDisabledReleasesStaleFn() {
        fnDown()
        XCTAssertEqual(changes, [true])
        held = false  // the key-up was lost while the tap was off
        disabled(.tapDisabledByTimeout)
        XCTAssertEqual(changes, [true, false])
        fnUp()  // a late real key-up must not end anything twice
        XCTAssertEqual(changes, [true, false])
    }

    func testTapDisabledKeepsHeldFn() {
        fnDown()
        held = true
        disabled(.tapDisabledByTimeout)
        XCTAssertEqual(changes, [true], "fn is still down, so the hold goes on")
        fnUp()
        XCTAssertEqual(changes, [true, false])
    }

    func testUserInputDisableAlsoReconciles() {
        fnDown()
        held = false
        disabled(.tapDisabledByUserInput)
        XCTAssertEqual(changes, [true, false])
    }

    func testIdleDisableDoesNothing() {
        held = false
        disabled(.tapDisabledByTimeout)
        disabled(.tapDisabledByUserInput)
        XCTAssertEqual(changes, [])
    }

    func testOtherKeyWhileFnDownIsReported() {
        tap.handle(.keyDown, key(125))  // Down arrow without fn
        XCTAssertEqual(otherKeys, 0)
        fnDown()
        tap.handle(.keyDown, key(125, fn: true))
        tap.handle(.keyUp, key(125, fn: true))  // key-ups are not new keys
        XCTAssertEqual(otherKeys, 1)
        XCTAssertEqual(changes, [true], "another key does not end the fn hold here; FnGesture decides")
    }

    func testGlobeKeyIsFn() {
        tap.handle(.keyDown, key(179))
        tap.handle(.keyDown, key(179))  // key repeat
        tap.handle(.keyUp, key(179))
        XCTAssertEqual(changes, [true, false])
    }
}
