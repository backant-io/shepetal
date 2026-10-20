import CoreGraphics
import XCTest
import ShepetalCore
@testable import Shepetal

/// The tap's event handling without a real tap. macOS turns a slow tap off and drops the events in between,
/// so a key-up can be lost; if the key is no longer held when the tap comes back, it must be released,
/// or a hold would run until the next press and a stuck key would block every shortcut.
final class FnTapTests: XCTestCase {
    var up: Set<Int> = []  // keys the system reports up
    var inputs: [KeyInput] = []
    var times: [TimeInterval] = []
    var tap: FnTap!

    override func setUp() {
        tap = FnTap()
        tap.isUp = { [unowned self] in self.up.contains($0) }
        tap.onInput = { [unowned self] in self.inputs.append($0); self.times.append($1) }
    }

    var changes: [Bool] { inputs.compactMap { $0 == .pttDown ? true : $0 == .pttUp ? false : nil } }
    var otherKeys: Int { inputs.filter { $0 == .otherKey }.count }

    /// A hardware-like event: pid 0, because the tap ignores events this process posted (its own Cmd+V).
    func key(_ code: Int64, fn: Bool = false, type: CGEventType = .keyDown, flags: CGEventFlags = []) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: type != .keyUp)!
        e.type = type
        e.flags = flags.union(fn ? .maskSecondaryFn : [])
        e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return e
    }

    @discardableResult func send(_ type: CGEventType, _ e: CGEvent) -> Bool { tap.handle(type, e) }
    func fnDown() { send(.flagsChanged, key(63, fn: true, type: .flagsChanged)) }
    func fnUp() { send(.flagsChanged, key(63, type: .flagsChanged)) }
    func disabled(_ type: CGEventType) { send(type, CGEvent(source: nil)!) }

    func testTapDisabledReleasesStaleFn() {
        fnDown()
        XCTAssertEqual(changes, [true])
        up = [63]  // the key-up was lost while the tap was off
        disabled(.tapDisabledByTimeout)
        XCTAssertEqual(changes, [true, false])
        fnUp()  // a late real key-up must not end anything twice
        XCTAssertEqual(changes, [true, false])
    }

    func testTapDisabledKeepsHeldFn() {
        fnDown()
        up = []
        disabled(.tapDisabledByTimeout)
        XCTAssertEqual(changes, [true], "fn is still down, so the hold goes on")
        fnUp()
        XCTAssertEqual(changes, [true, false])
    }

    func testUserInputDisableAlsoReconciles() {
        fnDown()
        up = [63]
        disabled(.tapDisabledByUserInput)
        XCTAssertEqual(changes, [true, false])
    }

    func testIdleDisableDoesNothing() {
        up = [63]
        disabled(.tapDisabledByTimeout)
        disabled(.tapDisabledByUserInput)
        XCTAssertEqual(inputs, [])
    }

    func testOtherKeyWhileFnDownIsReported() {
        send(.keyDown, key(125))  // Down arrow without fn
        send(.keyUp, key(125, type: .keyUp))
        XCTAssertEqual(otherKeys, 0)
        fnDown()
        send(.keyDown, key(125, fn: true))
        send(.keyUp, key(125, fn: true, type: .keyUp))  // key-ups are not new keys
        XCTAssertEqual(otherKeys, 1)
        XCTAssertEqual(changes, [true], "another key does not end the fn hold here; FnGesture decides")
    }

    // macOS also sends the Globe key as keycode 179 key events. Wispr calls them "doubleFn" and drops them before any
    // shortcut handling. Read as fn, the 179 pair after a release was a second tap: one short tap started hands-free
    // and a double-tap stopped itself (Pavel's M-FN-3 and M-FN-2, 2026-10-21). Only keycode 63 is fn, and 179 is not
    // another key either, so it never cancels a hold as a shortcut.
    func testGlobeKeyEventsAreIgnored() {
        fnDown()
        XCTAssertFalse(send(.keyDown, key(179, fn: true)))
        send(.keyUp, key(179, fn: true, type: .keyUp))
        fnUp()
        send(.keyDown, key(179))
        send(.keyDown, key(179))  // key repeat
        send(.keyUp, key(179, type: .keyUp))
        XCTAssertEqual(changes, [true, false], "one tap is one press, wherever the 179 events fall")
        XCTAssertEqual(otherKeys, 0, "179 while fn is held is not a shortcut")
        XCTAssertEqual(tap.router.held, [])
    }

    // The gesture is timed by when the key moved, not by when the main thread gets to it (#79).
    func testInputsCarryTheEventTime() {
        let e = key(63, fn: true, type: .flagsChanged)
        let t = ProcessInfo.processInfo.systemUptime - 0.4
        e.timestamp = CGEventTimestamp(t * 1e9)
        send(.flagsChanged, e)
        XCTAssertEqual(inputs, [.pttDown])
        XCTAssertEqual(times.first ?? 0, t, accuracy: 0.001)
    }

    // Secure input can hide a key-up (Tab into a password field). The key stays held, so every later fn press is
    // {Tab, fn}, matches no chord, and fn is dead. A press releases any held key the system reports up.
    func testLostKeyUpDoesNotBlockFn() {
        send(.keyDown, key(48))  // Tab, whose key-up never comes
        up = [48]
        fnDown()
        XCTAssertEqual(inputs, [.pttDown])
        XCTAssertEqual(tap.router.held, [63])
    }

    // The same for a modifier, through the real tap: the next event's flags no longer have ⌘.
    func testStaleModifierIsDroppedByTheNextEventsFlags() {
        send(.flagsChanged, key(55, type: .flagsChanged, flags: .maskCommand.union(CGEventFlags(rawValue: 0x8))))
        XCTAssertEqual(tap.router.held, [55])
        fnDown()  // flags: fn only
        XCTAssertEqual(inputs, [.pttDown])
        XCTAssertEqual(tap.router.held, [63])
    }

    // After a re-enable every held key the system reports up is released, not only fn: a stuck Ctrl would
    // otherwise keep ⌃⌘V from ever matching again.
    func testReenableReleasesEveryKeyReportedUp() {
        fnDown()
        send(.flagsChanged, key(59, fn: true, type: .flagsChanged, flags: .maskControl.union(CGEventFlags(rawValue: 0x1))))
        send(.keyDown, key(9, fn: true, flags: .maskControl))
        XCTAssertEqual(tap.router.held, [63, 59, 9])
        up = [59, 9]  // fn is still held
        disabled(.tapDisabledByTimeout)
        XCTAssertEqual(tap.router.held, [63], "Ctrl and V released, fn kept")
        XCTAssertEqual(changes, [true], "the hold goes on")
        up = [63, 59, 9]
        disabled(.tapDisabledByTimeout)
        XCTAssertEqual(tap.router.held, [])
        XCTAssertEqual(changes, [true, false])
    }

    // Our own synthesized Cmd+V must not count as keys: with ⌃⌘ still held it would fire paste last again.
    func testOwnEventsAreIgnored() {
        let own = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!  // carries this process's pid
        XCTAssertFalse(send(.keyDown, own))
        XCTAssertEqual(tap.router.held, [])
        XCTAssertEqual(inputs, [])
    }

    // Mouse buttons 3 to 10 are chord keys; CGEvent numbers them from 0.
    func testMouseButtonIsAKey() {
        XCTAssertNil(tap.updateRouter { $0.shortcuts.set([Key.mouse(4)], for: .ptt) })
        let e = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center)!
        e.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertFalse(send(.otherMouseDown, e), "a listen-only tap never drops")
        XCTAssertEqual(changes, [true])
        e.type = .otherMouseUp
        send(.otherMouseUp, e)
        XCTAssertEqual(changes, [true, false])
    }
}
