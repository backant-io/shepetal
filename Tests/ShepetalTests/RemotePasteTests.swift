import AppKit
import Carbon
import XCTest
import ShepetalCore
@testable import Shepetal

/// F22 on the inserter: remote viewers, Shift+Insert and typed text. Every test runs on a private pasteboard and
/// captures the key events instead of posting them, so the user's clipboard and focus are never touched.
@MainActor
final class RemotePasteTests: XCTestCase {
    var pasteboard: NSPasteboard!
    var events: [CGEvent] = []
    var keyDowns: [Int64] { events.filter { $0.type == .keyDown }.map { $0.getIntegerValueField(.keyboardEventKeycode) } }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
        events = []
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    // Windows App and other eager viewers read the clipboard during the delay, before the chord, and the far side
    // pastes that copy. Before F22 this was logged paste_failed with the wrong hint while the text had landed.
    func testEagerViewerThatReadsBeforeTheChordLands() async {
        let inserter = Inserter(pasteboard: pasteboard)
        var readAt: TimeInterval?, readText: String?, chordAt: TimeInterval?
        let pb = pasteboard!
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            readAt = ProcessInfo.processInfo.systemUptime
            readText = pb.string(forType: .string)
        }
        let start = now
        let r = await inserter.insert("Hello over there.", mode: .remote, sendPaste: { [unowned self] in
            if $0.type == .keyDown, chordAt == nil { chordAt = now }
            events.append($0)
        })
        XCTAssertTrue(r.landed, "a read before the chord is the remote paste")
        XCTAssertEqual(readText, "Hello over there.")
        XCTAssertLessThan(readAt ?? .infinity, chordAt ?? 0, "the stub read before the chord")
        XCTAssertGreaterThanOrEqual((chordAt ?? 0) - start, PasteMode.defaultDelay - 0.02, "the chord waits for the viewer's sync")
        XCTAssertEqual(keyDowns, [Int64(Inserter.vKeyCode())], "remote mode still sends ⌘V")
        XCTAssertGreaterThanOrEqual(now - (chordAt ?? now), PasteMode.remoteGrace - 0.02, "the restore waits the grace after the chord")
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier", "then the old clipboard comes back")
        XCTAssertTrue(r.restored)
    }

    // A viewer that fetches after the local restore point (0.5 s after a read) must still get the dictation.
    func testLateViewerStillGetsTheDictationNotTheOldClipboard() async {
        let inserter = Inserter(pasteboard: pasteboard)
        let pb = pasteboard!
        var late: String?
        let r = await inserter.insert("Late but right.", mode: .remote, sendPaste: { event in
            guard event.type == .keyDown else { return }
            _ = pb.string(forType: .string)  // the viewer reads at the chord
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                late = pb.string(forType: .string)  // and the far side fetches again later
            }
        })
        XCTAssertTrue(r.landed)
        XCTAssertEqual(late, "Late but right.", "0.8 s after the chord the clipboard still holds the dictation")
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier")
    }

    // A viewer that never reads did not paste: the text waits on the clipboard for ⌘V, as in local mode.
    func testViewerThatNeverReadsIsNotLanded() async {
        let r = await Inserter(pasteboard: pasteboard).insert("Nobody took it.", mode: .remote, sendPaste: { [unowned self] in events.append($0) })
        XCTAssertFalse(r.landed)
        XCTAssertEqual(pasteboard.string(forType: .string), "Nobody took it.")
    }

    // Rule 8 after the delay: focus that moved during it means no chord at all.
    func testFocusMovedDuringTheDelayPostsNoChord() async {
        let r = await Inserter(pasteboard: pasteboard).insert("Not here.", mode: .remote, sendPaste: { [unowned self] in events.append($0) },
                                                             stillFocused: { false })
        XCTAssertFalse(r.landed)
        XCTAssertTrue(events.isEmpty, "nothing is pasted into the window that took focus")
        XCTAssertEqual(pasteboard.string(forType: .string), "Not here.")
    }

    // Shift+Insert for Linux terminals in a remote session: the Insert key with Shift only, never ⌘ or a held fn.
    func testShiftInsertIsTheInsertKeyWithShiftOnly() async {
        let chord = Inserter.shiftInsert()
        XCTAssertEqual(chord.map { $0.type }, [.keyDown, .keyUp])
        for e in chord {
            XCTAssertEqual(e.getIntegerValueField(.keyboardEventKeycode), 0x72)
            XCTAssertTrue(e.flags.contains(.maskShift))
            XCTAssertTrue(e.flags.isDisjoint(with: [.maskCommand, .maskSecondaryFn, .maskAlternate, .maskControl]))
        }
        let pb = pasteboard!
        let r = await Inserter(pasteboard: pasteboard).insert("ls -la", mode: .shiftInsert, sendPaste: { [unowned self] in
            if $0.type == .keyDown { _ = pb.string(forType: .string) }
            events.append($0)
        })
        XCTAssertTrue(r.landed)
        XCTAssertEqual(keyDowns, [0x72], "the mode posts Shift+Insert instead of ⌘V")
    }

    // Typed text is key presses from the layout: the clipboard is never written, and capitals hold Shift down.
    func testTypedModeTypesEachKeyAndNeverTouchesTheClipboard() async throws {
        let layout = Inserter.layout()
        let keys = try XCTUnwrap(PasteMode.keystrokes("Hi there", layout: layout), "Latin letters type on every Mac layout")
        let change = pasteboard.changeCount
        let r = await Inserter(pasteboard: pasteboard).insert("Hi there", mode: .typed, sendPaste: { [unowned self] in events.append($0) })
        XCTAssertTrue(r.landed)
        XCTAssertEqual(pasteboard.changeCount, change, "typed text never touches the clipboard")
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       keys.flatMap(Inserter.events).map { $0.getIntegerValueField(.keyboardEventKeycode) })
        XCTAssertEqual(keyDowns.filter { $0 != 56 && $0 != 58 }, keys.map { Int64($0.code) })
    }

    // A key that needs Shift is Shift down, the key with Shift, Shift up: what a keyboard sends, on any layout.
    // A viewer that tracks the Shift key, not the flags on the key, still types a capital.
    func testShiftedKeyIsWrappedInShiftDownAndUp() {
        let e = Inserter.events(PasteMode.Keystroke(code: 4, shift: true))
        XCTAssertEqual(e.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [56, 4, 4, 56])
        guard e.count == 4 else { return }
        XCTAssertEqual(e.map { $0.type }, [.flagsChanged, .keyDown, .keyUp, .flagsChanged], "a modifier key is a flags change")
        XCTAssertTrue(e[0].flags.contains(.maskShift) && e[1].flags.contains(.maskShift) && e[2].flags.contains(.maskShift))
        XCTAssertFalse(e[3].flags.contains(.maskShift), "Shift is up again after the key")
        XCTAssertTrue(e.allSatisfy { $0.flags.isDisjoint(with: [.maskCommand, .maskSecondaryFn, .maskControl]) })
        XCTAssertEqual(Inserter.events(PasteMode.Keystroke(code: 34)).count, 2, "a plain key has no modifier events")
    }

    // A dead key is no key for its accent: posted, it types nothing and joins the next key in the target app. On a
    // German layout "^abc" typed "âbc", "`echo`" typed "ècho`", and a text ending in one joined the user's next
    // keystroke. Real layouts, read without switching the user's: the defect was the flag UCKeyTranslate got.
    func testDeadKeysAreNeverTyped() throws {
        let qwertz = Inserter.layout(try Self.source("com.apple.keylayout.ABC-QWERTZ"))
        for c in "^`´~¨" { XCTAssertNil(qwertz[c], "\(c) is only a dead key on ABC-QWERTZ") }
        XCTAssertNil(PasteMode.keystrokes("^abc", layout: qwertz), "so the text goes to the clipboard with the ⌘V hint")
        XCTAssertNil(PasteMode.keystrokes("`echo`", layout: qwertz))
        XCTAssertNotNil(PasteMode.keystrokes("echo abc", layout: qwertz))
        // On US, Option+E is the dead acute and Shift+Option+E types it alone; "`" and "^" are plain keys there.
        let us = Inserter.layout(try Self.source("com.apple.keylayout.US"))
        XCTAssertEqual(us["´"], PasteMode.Keystroke(code: 14, shift: true, option: true))
        XCTAssertNotNil(PasteMode.keystrokes("^abc `echo`", layout: us))
    }

    /// A keyboard layout that ships with macOS, by id. Reading it does not change the user's input source.
    static func source(_ id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return try XCTUnwrap(list?.first, "\(id) ships with macOS")
    }

    // A character the layout cannot type sends the whole text to the clipboard with the ⌘V hint, nothing typed.
    func testUntypableCharacterFallsBackToTheClipboard() async {
        let r = await Inserter(pasteboard: pasteboard).insert("Hi 日本", mode: .typed, sendPaste: { [unowned self] in events.append($0) })
        XCTAssertFalse(r.landed)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hi 日本")
    }

    // Rule 8 between keys: when focus moves mid-text, typing stops and the text waits on the clipboard.
    func testTypingStopsWhenFocusMoves() async {
        var asked = 0
        let r = await Inserter(pasteboard: pasteboard).insert("abcdef", mode: .typed, sendPaste: { [unowned self] in events.append($0) },
                                                             stillFocused: { asked += 1; return asked <= 2 })
        XCTAssertFalse(r.landed)
        XCTAssertEqual(keyDowns.count, 2, "only the keys before the move were typed")
        XCTAssertEqual(pasteboard.string(forType: .string), "abcdef")
    }
}
