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

    // "fn not received" comes only from what the tap itself sees (FnHealth): a 🌐 keycode 179 keyDown that no
    // keycode 63 came with. Pavel got it for keys that are not fn (2026-10-21): typing, modifiers, shortcuts and fn+key
    // must never alert. Raw flags carry the device bits the tap reads (⌃ 0x1, ⇧ 0x2, ⌘ 0x8, ⌥ 0x20, fn 0x800000).
    let (fnF, cmdF, shiftF, ctrlF, optF) = (UInt64(0x80_0000), UInt64(0x10_0008), UInt64(0x2_0002), UInt64(0x4_0001), UInt64(0x8_0020))
    let fnKeyF = UInt64(0x80_0000 | 0x20_0000)  // arrows and F-keys carry the fn (and numeric pad) flag themselves
    let fm = CGEventType.flagsChanged, kd = CGEventType.keyDown, ku = CGEventType.keyUp

    /// Sends `events` through the real tap, each `wait` s after the one before, into FnHealth on a test clock
    /// (polled every 0.1 s as it goes and for 3 s after). Returns how often "fn not received" would show.
    func fnNotReceived(_ events: [(type: CGEventType, code: Int64, flags: UInt64, wait: TimeInterval)]) -> Int {
        var health = FnHealth(), clock: TimeInterval = 100, alerts = 0
        tap.onFn = { down, _ in health.fn(down: down, at: clock) }
        tap.onGlobe = { _ in health.globe(at: clock) }
        func advance(_ s: TimeInterval) {
            for _ in 0..<max(1, Int((s / 0.1).rounded())) { clock += min(s, 0.1); if health.poll(at: clock) { alerts += 1 } }
        }
        for e in events {
            advance(e.wait)
            send(e.type, key(e.code, type: e.type, flags: CGEventFlags(rawValue: e.flags)))
        }
        advance(3)
        return alerts
    }

    func testTypingNeverSaysFnNotReceived() {
        var typing = [4, 14, 37, 37, 31, 49, 13, 31, 15, 37, 2, 36, 51].flatMap { c in
            [(type: kd, code: Int64(c), flags: UInt64(0), wait: 0.08), (type: ku, code: Int64(c), flags: UInt64(0), wait: 0.05)]
        }
        // A held Down arrow and a held F5 repeat for 1.5 s: their own events carry the fn flag.
        for c: Int64 in [125, 96] {
            typing += (0..<15).map { _ in (type: kd, code: c, flags: fnKeyF, wait: 0.1) } + [(type: ku, code: c, flags: fnKeyF, wait: 0.1)]
        }
        XCTAssertEqual(fnNotReceived(typing), 0)
    }

    func testModifierCombosAndShortcutsNeverSayFnNotReceived() {
        let combos: [(type: CGEventType, code: Int64, flags: UInt64, wait: TimeInterval)] = [
            (fm, 55, cmdF, 0.1), (kd, 8, cmdF, 0.1), (ku, 8, cmdF, 0.1), (fm, 55, 0, 0.1),                         // ⌘C
            (fm, 56, shiftF, 0.1), (kd, 0, shiftF, 0.1), (ku, 0, shiftF, 0.1), (fm, 56, 0, 0.1),                   // ⇧A
            (fm, 58, optF, 0.1), (kd, 123, optF | fnKeyF, 0.1), (ku, 123, optF | fnKeyF, 0.1), (fm, 58, 0, 0.1),   // ⌥←
            (fm, 59, ctrlF, 0.1), (fm, 58, ctrlF | optF, 0.1), (fm, 58, ctrlF, 1.5), (fm, 59, 0, 0.1),             // ⌃⌥ held
            (fm, 59, ctrlF, 0.1), (fm, 55, ctrlF | cmdF, 0.1), (kd, 9, ctrlF | cmdF, 0.1), (ku, 9, ctrlF | cmdF, 0.1),
            (fm, 55, ctrlF, 0.1), (fm, 59, 0, 0.1),                                                                 // ⌃⌘V paste last
            (fm, 55, cmdF, 0.1), (kd, 49, cmdF, 0.1), (ku, 49, cmdF, 0.1), (fm, 55, 0, 0.1),                       // ⌘Space
        ]
        XCTAssertEqual(fnNotReceived(combos), 0)
    }

    // ⌃ then fn held: fn reaches the tap but completes no shortcut. The old check counted only shortcut inputs as
    // "received", so this held fn said "fn not received".
    func testFnWithOtherKeysNeverSaysFnNotReceived() {
        let fnKeys: [(type: CGEventType, code: Int64, flags: UInt64, wait: TimeInterval)] = [
            (fm, 63, fnF, 0.1), (kd, 125, fnKeyF, 0.1), (ku, 125, fnKeyF, 0.1), (fm, 63, 0, 0.1),                  // fn+↓
            (fm, 63, fnF, 0.1), (kd, 51, fnF, 0.1), (ku, 51, fnF, 0.1), (fm, 63, 0, 0.1),                         // fn+Delete
            (fm, 59, ctrlF, 0.1), (fm, 63, ctrlF | fnF, 0.1), (fm, 63, ctrlF, 1.5), (fm, 59, 0, 0.1),             // ⌃ then fn
            (fm, 63, fnF, 0.1), (kd, 49, fnF, 0.1), (ku, 49, fnF, 0.1), (fm, 63, 0, 0.1),                         // fn+Space
            (fm, 63, fnF, 0.1), (kd, 179, fnF, 2), (ku, 179, fnF, 0.1), (fm, 63, 0, 0.1),                         // 🌐+key in a hold
        ]
        XCTAssertEqual(fnNotReceived(fnKeys), 0)
    }

    func testGlobeWithFnNeverSaysFnNotReceived() {
        // A 2 s hold, a short tap and a double-tap, each with the 179 pair macOS sends right after the release.
        let held: [(type: CGEventType, code: Int64, flags: UInt64, wait: TimeInterval)] = [
            (fm, 63, fnF, 0.1), (fm, 63, 0, 2), (kd, 179, 0, 0.01), (ku, 179, 0, 0.01),
            (fm, 63, fnF, 1), (fm, 63, 0, 0.15), (kd, 179, 0, 0.01), (ku, 179, 0, 0.01),
            (fm, 63, fnF, 1), (fm, 63, 0, 0.1), (kd, 179, 0, 0.01), (ku, 179, 0, 0.01),
            (fm, 63, fnF, 0.15), (fm, 63, 0, 0.1), (kd, 179, 0, 0.01), (ku, 179, 0, 0.01),
        ]
        XCTAssertEqual(fnNotReceived(held), 0)
    }

    func testGlobeAloneSaysFnNotReceived() {
        XCTAssertEqual(fnNotReceived([(kd, 179, 0, 0.1), (ku, 179, 0, 0.1)]), 1, "🌐 reached the tap, fn did not")
        XCTAssertEqual(fnNotReceived([(kd, 179, 0, 0.1), (ku, 179, 0, 0.1), (kd, 179, 0, 2), (ku, 179, 0, 0.1)]), 2,
                       "each unanswered 🌐 press")
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
