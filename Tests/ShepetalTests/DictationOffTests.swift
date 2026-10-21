import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F102: the 🤫 menu turns dictation off in the front app and back on. The front app is injected, so no test
/// reads or changes the real front app, and the list lives in a throwaway defaults suite.
@MainActor
final class DictationOffTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var frontApp = (bundleId: "com.apple.TextEdit", label: "TextEdit")
    private var off: DictationOff!

    override func setUp() async throws {
        suite = "shepetal-dictationoff-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        off = DictationOff(list: AppBlockList(defaults)) { [unowned self] in frontApp }
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func titles() -> [String] { off.menuItems().map(\.title) }
    private func item(_ title: String) throws -> NSMenuItem { try XCTUnwrap(off.menuItems().first { $0.title == title }) }

    /// M-BLOCK-1 in code: turn it off from the menu, fn shows the hint; turn it on, fn dictates again.
    func testMenuTurnsTheFrontAppOffAndOn() throws {
        XCTAssertEqual(titles(), ["Turn off dictation in TextEdit"], "nothing is off yet, so no submenu")
        XCTAssertNil(off.hint(for: .pttDown, idle: true))

        try item("Turn off dictation in TextEdit").click()
        XCTAssertEqual(off.hint(for: .pttDown, idle: true), "Dictation is off in TextEdit")
        XCTAssertEqual(titles(), ["Turn on dictation in TextEdit", "Dictation is off in (click to turn back on)"])

        try item("Turn on dictation in TextEdit").click()
        XCTAssertNil(off.hint(for: .pttDown, idle: true))
    }

    /// Off in one app only: switching to another app dictates as before.
    func testOnlyTheTurnedOffAppIsBlocked() throws {
        try item("Turn off dictation in TextEdit").click()
        frontApp = ("com.apple.Notes", "Notes")
        XCTAssertNil(off.hint(for: .pttDown, idle: true))
        XCTAssertEqual(titles(), ["Turn off dictation in Notes", "Dictation is off in (click to turn back on)"])
    }

    /// The submenu lists every app turned off, by name, and a click turns that one back on from any app.
    func testSubmenuTurnsAnAppBackOnFromElsewhere() throws {
        try item("Turn off dictation in TextEdit").click()
        frontApp = ("com.microsoft.rdc.macos", "Windows App")
        try item("Turn off dictation in Windows App").click()
        frontApp = ("com.apple.Notes", "Notes")

        let sub = try XCTUnwrap(item("Dictation is off in (click to turn back on)").submenu)
        XCTAssertEqual(sub.items.map(\.title), ["TextEdit", "Windows App"])
        sub.items[0].click()
        XCTAssertEqual(AppBlockList(defaults).apps, ["com.microsoft.rdc.macos": "Windows App"])
    }

    /// No front app, or shepetal's own window in front: there is nothing to turn off.
    func testNoItemWithoutAFrontApp() throws {
        frontApp = ("", "")
        XCTAssertEqual(titles(), [])
        XCTAssertNil(off.hint(for: .pttDown, idle: true))
        frontApp = (try XCTUnwrap(Bundle.main.bundleIdentifier), "shepetal")
        XCTAssertEqual(titles(), [])
    }
}

private extension NSMenuItem {
    /// What a click on the item does.
    func click() { _ = (target as? NSObject)?.perform(action, with: self) }
}
