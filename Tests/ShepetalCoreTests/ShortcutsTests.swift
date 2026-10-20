import XCTest
@testable import ShepetalCore

/// Custom shortcuts (docs/re/dictation-input.md 1 and 2.4): the Mac defaults, the rules a new chord must
/// pass, held-set matching, and which events the tap drops so the front app never sees them.
final class ShortcutsTests: XCTestCase {
    let (fn, cmd, ctrl, opt, shift) = (Key.fn, Key.cmd, Key.ctrl, Key.opt, Key.shift)
    let (esc, space, v, c) = (Key.esc, Key.space, Key.v, Key.c)

    func testDefaults() {
        let s = Shortcuts()
        XCTAssertEqual(s.chord(.ptt), [fn])
        XCTAssertEqual(s.chord(.handsFree), [fn, space])
        XCTAssertEqual(s.chord(.dismiss), [esc])
        XCTAssertEqual(s.chord(.pasteLast), [ctrl, cmd, v])
        XCTAssertEqual(s.chord(.copyLast), [ctrl, cmd, c])
        for action in ShortcutAction.allCases {
            XCTAssertNil(s.problem(s.chord(action), for: action), "the default for \(action) must pass its own rules")
        }
    }

    func testRejectsFourKeys() {
        XCTAssertEqual(Shortcuts().problem([ctrl, opt, shift, Key.a], for: .copyLast), .tooManyKeys)
        XCTAssertNil(Shortcuts().problem([ctrl, opt, Key.a], for: .copyLast), "3 keys is the limit, not over it")
    }

    // A bare key would fire every time the user types it.
    func testRejectsBareLetterAndDigit() {
        let s = Shortcuts()
        XCTAssertEqual(s.problem([Key.a], for: .pasteLast), .noModifier)
        XCTAssertEqual(s.problem([18], for: .pasteLast), .noModifier, "the 1 key")
        XCTAssertEqual(s.problem([Key.a, 18], for: .pasteLast), .noModifier, "two typing keys are still no modifier")
        XCTAssertEqual(s.problem([47], for: .ptt), .noModifier, "punctuation")
        XCTAssertEqual(s.problem([esc], for: .ptt), .noModifier, "Esc alone is allowed for cancel only")
    }

    func testRejectsLeftAndRightCommand() {
        XCTAssertEqual(Shortcuts().problem([cmd, Key.rightCmd, Key.a], for: .copyLast), .leftRightSame)
        XCTAssertNil(Shortcuts().problem([Key.rightCmd, ctrl, Key.a], for: .copyLast), "one right-hand modifier is fine")
    }

    func testRejectsChordInUse() {
        var s = Shortcuts()
        XCTAssertEqual(s.problem([ctrl, cmd, v], for: .copyLast), .inUse, "paste last has it")
        XCTAssertEqual(s.problem([Key.rightCtrl, cmd, v], for: .copyLast), .inUse, "either side of a modifier is the same chord")
        XCTAssertNil(s.problem([ctrl, cmd, v], for: .pasteLast), "rebinding an action to its own chord is fine")
        XCTAssertEqual(s.set([fn], for: .copyLast), .inUse)
        XCTAssertEqual(s.chord(.copyLast), [ctrl, cmd, c], "a refused chord changes nothing")
    }

    func testRejectsSystemShortcut() {
        let s = Shortcuts()
        XCTAssertEqual(s.problem([cmd, Key.tab], for: .pasteLast), .blocked)
        XCTAssertEqual(s.problem([Key.rightCmd, Key.tab], for: .pasteLast), .blocked, "right Command too")
        for chord: Set<Int> in [[cmd, space], [ctrl, space], [cmd, Key.q], [cmd, Key.w], [cmd, c], [cmd, v],
                                [cmd, Key.x], [cmd, Key.z], [cmd, Key.a], [cmd, shift, Key.four], [ctrl, Key.left],
                                [fn, Key.delete]] {
            XCTAssertEqual(s.problem(chord, for: .copyLast), .blocked, Key.label(chord))
        }
    }

    func testAcceptsMouseButton4AndCtrlOpt() {
        var s = Shortcuts()
        XCTAssertNil(s.set([Key.mouse(4)], for: .ptt), "a mouse button counts as a modifier")
        XCTAssertNil(s.set([ctrl, opt], for: .handsFree), "modifiers alone are a chord")
        XCTAssertEqual(s.chord(.ptt), [Key.mouse(4)])
        XCTAssertEqual(s.action(held: [Key.mouse(4)]), .ptt)
        XCTAssertEqual(s.action(held: [Key.rightCtrl, opt]), .handsFree)
    }

    func testFnAndGlobeAreOneKey() {
        var s = Shortcuts()
        XCTAssertEqual(s.action(held: [Key.globe]), .ptt)
        XCTAssertEqual(s.action(held: [Key.globe, space]), .handsFree)
        XCTAssertEqual(s.problem([Key.globe], for: .copyLast), .inUse, "Globe is fn, which hold-to-talk has")
        XCTAssertNil(s.set([Key.globe, Key.s], for: .copyLast))
        XCTAssertEqual(s.chord(.copyLast), [fn, Key.s], "stored as fn")

        var r = KeyRouter()
        XCTAssertEqual(r.key(fn, down: true, active: false, canSwallow: true).inputs, [.pttDown])
        XCTAssertEqual(r.key(Key.globe, down: true, active: true, canSwallow: true).inputs, [], "the twin of a held key is not a new press")
        XCTAssertEqual(r.key(Key.globe, down: false, active: true, canSwallow: true).inputs, [], "fn is still down")
        XCTAssertEqual(r.key(fn, down: false, active: true, canSwallow: true).inputs, [.pttUp])
    }

    // The action fires only when the held set is exactly its chord.
    func testHeldSetMatching() {
        var r = KeyRouter()
        func press(_ keys: [Int]) -> [KeyInput] {
            defer { for k in keys.reversed() { _ = r.key(k, down: false, active: false, canSwallow: true) } }
            return keys.flatMap { r.key($0, down: true, active: false, canSwallow: true).inputs }
        }
        XCTAssertEqual(press([ctrl, cmd, v]), [.pasteLast])
        XCTAssertEqual(press([Key.rightCmd, Key.rightCtrl, c]), [.copyLast])
        XCTAssertFalse(press([v]).contains(.pasteLast), "V alone")
        XCTAssertFalse(press([cmd, v]).contains(.pasteLast), "Cmd+V is the app's paste")
        XCTAssertFalse(press([shift, ctrl, cmd, v]).contains(.pasteLast), "an extra key is another chord")
        XCTAssertEqual(r.held, [])

        // Key repeat of a matched chord fires once.
        _ = r.key(ctrl, down: true, active: false, canSwallow: true)
        _ = r.key(cmd, down: true, active: false, canSwallow: true)
        routed(r.key(v, down: true, active: false, canSwallow: true), [.pasteLast], true)
        routed(r.key(v, down: true, active: false, canSwallow: true), [], true, "repeat: dropped, not fired again")
    }

    func testSwallowDecision() {
        var r = KeyRouter()
        // Esc while idle is the app's Esc.
        var out = r.key(esc, down: true, active: false, canSwallow: true)
        XCTAssertFalse(out.swallow)
        XCTAssertFalse(out.inputs.contains(.dismiss))
        XCTAssertFalse(r.key(esc, down: false, active: false, canSwallow: true).swallow)

        // Esc while recording, and while transcribing (both are `active`), is ours: dropped, with its key-up.
        for _ in 0..<2 {
            routed(r.key(esc, down: true, active: true, canSwallow: true), [.dismiss], true)
            XCTAssertTrue(r.key(esc, down: false, active: false, canSwallow: true).swallow, "key-up of a dropped key-down")
        }

        // fn+Space: fn is a modifier and passes; Space is dropped, down and up.
        routed(r.key(fn, down: true, active: false, canSwallow: true), [.pttDown], false)
        routed(r.key(space, down: true, active: true, canSwallow: true), [.toggle], true)
        routed(r.key(space, down: false, active: true, canSwallow: true), [], true)
        routed(r.key(fn, down: false, active: true, canSwallow: true), [.pttUp], false)

        // A plain Space is typing. During a dictation it is reported, so FnGesture can tell a chord from typing.
        out = r.key(space, down: true, active: true, canSwallow: true)
        XCTAssertEqual(out.inputs, [.otherKey])
        XCTAssertFalse(out.swallow)
        _ = r.key(space, down: false, active: true, canSwallow: true)
        routed(r.key(space, down: true, active: false, canSwallow: true), [], false, "idle: not even reported")
        _ = r.key(space, down: false, active: false, canSwallow: true)

        // Listen-only tap (no Accessibility): the actions still fire, nothing is dropped.
        routed(r.key(esc, down: true, active: true, canSwallow: false), [.dismiss], false)
        XCTAssertFalse(r.key(esc, down: false, active: true, canSwallow: false).swallow)
        _ = r.key(fn, down: true, active: false, canSwallow: false)
        routed(r.key(space, down: true, active: true, canSwallow: false), [.toggle], false)
    }

    // The Shortcuts window records through the tap: the whole chord comes back on release and fires nothing.
    func testRecordingCapturesTheChordAndFiresNothing() {
        var r = KeyRouter()
        r.record()
        XCTAssertEqual(r.key(Key.rightCtrl, down: true, active: false, canSwallow: true).inputs, [])
        XCTAssertEqual(r.key(cmd, down: true, active: false, canSwallow: true).inputs, [])
        routed(r.key(v, down: true, active: false, canSwallow: true), [], true, "paste last must not fire")
        XCTAssertEqual(r.key(v, down: false, active: false, canSwallow: true).inputs, [])
        XCTAssertEqual(r.key(cmd, down: false, active: false, canSwallow: true).inputs, [])
        XCTAssertEqual(r.key(Key.rightCtrl, down: false, active: false, canSwallow: true).inputs,
                       [.recorded([Key.rightCtrl, cmd, v])], "as pressed, so left and right can be checked")
        XCTAssertFalse(r.isRecording)
        XCTAssertEqual(r.key(fn, down: true, active: false, canSwallow: true).inputs, [.pttDown], "back to normal")
    }

    // After the tap was off, keys whose key-up was lost are released, and a lost fn-up ends the hold.
    func testReleaseStaleReleasesKeysReportedUp() {
        var r = KeyRouter()
        _ = r.key(fn, down: true, active: false, canSwallow: true)
        _ = r.key(ctrl, down: true, active: true, canSwallow: true)
        _ = r.key(Key.mouse(4), down: true, active: true, canSwallow: true)
        XCTAssertEqual(r.releaseStale { $0 == ctrl }, [], "Ctrl was not part of the hold")
        XCTAssertEqual(r.held, [fn, Key.mouse(4)])
        XCTAssertEqual(r.releaseStale { _ in true }, [.pttUp])
        XCTAssertEqual(r.held, [])
        XCTAssertEqual(r.key(fn, down: true, active: false, canSwallow: true).inputs, [.pttDown], "fn works again")
    }

    func testModifierFlags() {
        XCTAssertEqual(Key.modifierDown(fn, flags: 0x80_0100), true)
        XCTAssertEqual(Key.modifierDown(fn, flags: 0x100), false)
        XCTAssertEqual(Key.modifierDown(Key.globe, flags: 0x80_0000), true)
        XCTAssertEqual(Key.modifierDown(cmd, flags: 0x10_0010), false, "only right Command is down")
        XCTAssertEqual(Key.modifierDown(Key.rightCmd, flags: 0x10_0010), true)
        XCTAssertNil(Key.modifierDown(57, flags: 0x1_0000), "Caps Lock is not tracked")
        XCTAssertNil(Key.modifierDown(Key.left, flags: 0x80_0000), "arrows carry the fn flag but are not fn")
        XCTAssertTrue(Key.flagUp(Key.rightCmd, flags: 0x80_0000), "no Command flag at all")
        XCTAssertFalse(Key.flagUp(cmd, flags: 0x10_0000))
        XCTAssertFalse(Key.flagUp(v, flags: 0), "not a modifier")
        XCTAssertTrue(Key.flagUp(fn, flags: 0))
        XCTAssertFalse(Key.flagUp(Key.globe, flags: 0), "Globe as a key event is released by its key-up")
    }

    // A modifier released where the tap could not see it (a password field) must not block every chord.
    func testStaleModifierIsDroppedByTheNextEventsFlags() {
        var r = KeyRouter()
        _ = r.key(cmd, down: true, active: false, canSwallow: true)
        XCTAssertEqual(r.key(fn, down: true, active: false, canSwallow: true).inputs, [], "Cmd+fn is no chord")
        _ = r.key(fn, down: false, active: false, canSwallow: true)
        let flags: UInt64 = 0x80_0000  // the next fn press: fn down, no Command
        XCTAssertEqual(r.releaseStale { $0 != fn && Key.flagUp($0, flags: flags) }, [])
        XCTAssertEqual(r.key(fn, down: true, active: false, canSwallow: true).inputs, [.pttDown])
    }

    func testStoredBindingsRoundTripAndReset() {
        var s = Shortcuts()
        XCTAssertNil(s.set([ctrl, opt], for: .ptt))
        let back = Shortcuts(stored: s.stored)
        XCTAssertEqual(back, s)
        XCTAssertEqual(Shortcuts(stored: ["ptt": [], "nonsense": [1]]), Shortcuts(), "empty and unknown entries fall back")
        s.reset()
        XCTAssertEqual(s, Shortcuts())
    }

    func testLabels() {
        XCTAssertEqual(Key.label([space, fn]), "fn Space")
        XCTAssertEqual(Key.label([v, cmd, Key.rightCtrl]), "⌃ ⌘ V")
        XCTAssertEqual(Key.label([Key.mouse(4)]), "Mouse 4")
        XCTAssertEqual(Key.label([esc]), "Esc")
        XCTAssertEqual(Key.label([cmd, 50]), "⌘ `")
        XCTAssertEqual(Key.label([opt, 18, 29]), "⌥ 1 0")
    }

    // Paste last and copy last use the newest text, whatever happened to it; rows without text are skipped.
    func testLastTextPicksNewestNonEmptyIncludingPasteFailed() {
        func row(_ s: TimeInterval, _ outcome: Outcome, _ text: String) -> HistoryEntry {
            HistoryEntry(id: "\(s)", createdAt: Date(timeIntervalSince1970: s), outcome: outcome, audioPath: "", durationMs: 0, text: text)
        }
        let rows = [row(5, .tooShort, ""), row(4, .failed, ""), row(3, .pasteFailed, "the one that did not land"),
                    row(2, .inserted, "older"), row(1, .inserted, "oldest")]
        XCTAssertEqual(lastText(in: rows), "the one that did not land")
        XCTAssertEqual(lastText(in: rows.reversed()), "the one that did not land", "by time, not by list order")
        XCTAssertEqual(lastText(in: [row(9, .cancelled, "kept from an Esc")] + rows), "kept from an Esc")
        XCTAssertNil(lastText(in: [row(1, .tooShort, "")]))
    }

    private func routed(_ out: (inputs: [KeyInput], swallow: Bool), _ inputs: [KeyInput], _ swallow: Bool,
                        _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(out.inputs, inputs, message, file: file, line: line)
        XCTAssertEqual(out.swallow, swallow, "swallow " + message, file: file, line: line)
    }
}
