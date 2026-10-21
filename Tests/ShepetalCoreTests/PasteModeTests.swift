import XCTest
@testable import ShepetalCore

/// F22: remote desktop and VM viewers get their own paste, everything else keeps today's ⌘V.
final class PasteModeTests: XCTestCase {
    // The viewers checked on Pavel's Mac (Windows App, Screen Sharing) are remote. Local terminals need no mode:
    // they take plain ⌘V (docs/re/insertion-context.md M8).
    func testRemoteViewersAreRemoteAndEverythingElseIsLocal() {
        for id in ["com.microsoft.rdc.macos", "com.apple.ScreenSharing", "com.realvnc.vncviewer"] {
            XCTAssertEqual(PasteMode.mode(for: id, overrides: nil), .remote, id)
        }
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.TextEdit", ""] {
            XCTAssertEqual(PasteMode.mode(for: id, overrides: nil), .local, id)
        }
    }

    // `pasteModes` wins both ways, and a typo never breaks the paste.
    func testUserOverrideWinsAndUnknownValuesAreIgnored() {
        let overrides: [String: Any] = ["com.microsoft.rdc.macos": "local", "com.apple.Terminal": "shift-insert",
                                        "com.apple.TextEdit": "typed", "com.apple.Notes": "telepathy", "com.apple.Mail": 3]
        XCTAssertEqual(PasteMode.mode(for: "com.microsoft.rdc.macos", overrides: overrides), .local)
        XCTAssertEqual(PasteMode.mode(for: "com.apple.Terminal", overrides: overrides), .shiftInsert)
        XCTAssertEqual(PasteMode.mode(for: "com.apple.TextEdit", overrides: overrides), .typed)
        XCTAssertEqual(PasteMode.mode(for: "com.apple.Notes", overrides: overrides), .local)
        XCTAssertEqual(PasteMode.mode(for: "com.apple.Mail", overrides: overrides), .local)
        XCTAssertEqual(PasteMode.mode(for: "com.apple.ScreenSharing", overrides: overrides), .remote)
    }

    // The override and the delay are read from the defaults, the way `defaults write` leaves them.
    func testOverridesAndDelayAreReadFromTheDefaults() throws {
        let suite = "shepetal-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PasteMode.delay(defaults), 0.3, accuracy: 1e-9, "about 300 ms by default")
        defaults.set(["com.apple.TextEdit": "typed"], forKey: PasteMode.overridesKey)
        defaults.set(800, forKey: PasteMode.delayKey)
        XCTAssertEqual(PasteMode.current(for: "com.apple.TextEdit", defaults: defaults), .typed)
        XCTAssertEqual(PasteMode.delay(defaults), 0.8, accuracy: 1e-9)
        defaults.set(-5, forKey: PasteMode.delayKey)
        XCTAssertEqual(PasteMode.delay(defaults), 0.3, accuracy: 1e-9, "a nonsense delay falls back")
    }

    // An eager viewer reads during the delay and the far side pastes its copy: that is the paste, not paste_failed.
    // Locally the same early read is a clipboard manager and still does not count.
    func testRemoteReadBeforeTheChordCountsAndLocalDoesNot() {
        XCTAssertEqual(PasteMode.verdict(.remote, postedAt: 10, requestedAt: 9.8, now: 10.01), .landed)
        XCTAssertEqual(PasteMode.verdict(.shiftInsert, postedAt: 10, requestedAt: 9.8, now: 10.01), .landed)
        XCTAssertEqual(PasteMode.verdict(.local, postedAt: 10, requestedAt: 9.8, now: 10.5), .waiting)
        XCTAssertEqual(PasteMode.verdict(.local, postedAt: 10, requestedAt: 9.8, now: 11), .failed)
        XCTAssertEqual(PasteMode.verdict(.remote, postedAt: 10, requestedAt: nil, now: 10.9), .waiting)
        XCTAssertEqual(PasteMode.verdict(.remote, postedAt: 10, requestedAt: nil, now: 11), .failed, "no read is no paste")
    }

    // A late remote fetch must still get the dictation, never the user's old clipboard.
    func testRemoteRestoreWaitsForTheGraceAfterTheChordOrTheRead() {
        XCTAssertEqual(PasteMode.restoreAt(.remote, postedAt: 10, requestedAt: 9.8), 11, accuracy: 1e-9)
        XCTAssertEqual(PasteMode.restoreAt(.remote, postedAt: 10, requestedAt: 10.4), 11.4, accuracy: 1e-9)
        XCTAssertEqual(PasteMode.restoreAt(.local, postedAt: 10, requestedAt: 10.05), 10.55, accuracy: 1e-9, "local is unchanged")
    }

    // Typed mode on a fixed layout: each character's key, or nothing at all when one cannot be typed.
    func testKeystrokesFollowTheLayoutAndFallBackWhole() {
        let h = PasteMode.Keystroke(code: 4, shift: true), i = PasteMode.Keystroke(code: 34), bang = PasteMode.Keystroke(code: 18, shift: true)
        let at = PasteMode.Keystroke(code: 37, option: true)
        let layout: [Character: PasteMode.Keystroke] = ["H": h, "i": i, "!": bang, "@": at, " ": .init(code: 49)]
        XCTAssertEqual(PasteMode.keystrokes("Hi!", layout: layout), [h, i, bang])
        XCTAssertEqual(PasteMode.keystrokes("i @", layout: layout), [i, .init(code: 49), at])
        XCTAssertNil(PasteMode.keystrokes("Hié", layout: layout), "one untypable character sends the whole text to the clipboard")
        XCTAssertNil(PasteMode.keystrokes("Hi\nHi", layout: layout), "a line break is never typed as Return")
        XCTAssertEqual(PasteMode.keystrokes("", layout: layout), [])
    }
}
