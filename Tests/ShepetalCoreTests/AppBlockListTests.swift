import XCTest
@testable import ShepetalCore

/// F102: fn does not dictate in an app the user turned off, and nothing else is ever blocked.
final class AppBlockListTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var list: AppBlockList!

    override func setUpWithError() throws {
        suite = "shepetal-appblock-test-\(UUID().uuidString)"  // never the app's own defaults
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        list = AppBlockList(defaults)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    /// The switch must survive a restart: a second list on the same defaults reads what the first one wrote.
    func testTurnedOffAppsAreStoredAndReadBack() {
        list.set("com.apple.TextEdit", name: "TextEdit", off: true)
        list.set("com.microsoft.rdc.macos", name: "Windows App", off: true)
        let again = AppBlockList(defaults)
        XCTAssertEqual(again.apps, ["com.apple.TextEdit": "TextEdit", "com.microsoft.rdc.macos": "Windows App"])
        again.set("com.apple.TextEdit", name: "", off: false)
        XCTAssertEqual(AppBlockList(defaults).apps, ["com.microsoft.rdc.macos": "Windows App"],
                       "turning one back on must keep the others off")
    }

    /// The bundle id decides, not the name: another app called the same must keep dictating.
    func testMatchesByExactBundleId() {
        list.set("com.apple.TextEdit", name: "TextEdit", off: true)
        XCTAssertTrue(list.blocks(bundleId: "com.apple.TextEdit"))
        XCTAssertFalse(list.blocks(bundleId: "com.apple.TextEdit.helper"))
        XCTAssertFalse(list.blocks(bundleId: "com.apple"))
        XCTAssertFalse(list.blocks(bundleId: "TextEdit"))
    }

    /// No front app, or an app without a bundle id, has nothing to match: blocking it would turn dictation off everywhere.
    func testAnEmptyBundleIdNeverMatches() {
        list.set("", name: "Nameless", off: true)
        XCTAssertEqual(list.apps, [:], "an empty id must not be stored")
        defaults.set(["": "Planted", "com.apple.TextEdit": "TextEdit"], forKey: AppBlockList.key)
        XCTAssertFalse(list.blocks(bundleId: ""))
        XCTAssertNil(list.hint(for: .pttDown, idle: true, bundleId: "", name: ""))
    }

    /// One bad stored value drops only itself, not the whole list.
    func testABadStoredValueKeepsTheRest() {
        defaults.set(["com.apple.TextEdit": "TextEdit", "bad": 3], forKey: AppBlockList.key)
        XCTAssertEqual(list.apps, ["com.apple.TextEdit": "TextEdit"])
        XCTAssertTrue(list.blocks(bundleId: "com.apple.TextEdit"))
    }

    /// A press that would start a dictation in a turned-off app shows the hint instead; nothing records.
    func testGateStopsAStartingPressInATurnedOffApp() {
        list.set("com.apple.TextEdit", name: "TextEdit", off: true)
        XCTAssertEqual(list.hint(for: .pttDown, idle: true, bundleId: "com.apple.TextEdit", name: "TextEdit"),
                       "Dictation is off in TextEdit")
        XCTAssertEqual(list.hint(for: .toggle, idle: true, bundleId: "com.apple.TextEdit", name: "TextEdit"),
                       "Dictation is off in TextEdit", "fn+Space must not start hands-free either")
        XCTAssertEqual(list.hint(for: .pttDown, idle: true, bundleId: "com.apple.TextEdit", name: ""),
                       "Dictation is off in TextEdit", "an app with no name at hand is named from the list")
        XCTAssertNil(list.hint(for: .pttDown, idle: true, bundleId: "com.apple.Notes", name: "Notes"),
                     "other apps keep dictating")
    }

    /// Ending a dictation must always work, or a session started elsewhere could not be stopped in this app.
    func testGateNeverStopsTheEndOfADictation() {
        list.set("com.apple.TextEdit", name: "TextEdit", off: true)
        for input in [KeyInput.pttDown, .toggle] {
            XCTAssertNil(list.hint(for: input, idle: false, bundleId: "com.apple.TextEdit", name: "TextEdit"),
                         "\(input) while recording stops the recording")
        }
        for input in [KeyInput.pttUp, .dismiss, .otherKey, .pasteLast, .copyLast, .recorded([63])] {
            XCTAssertNil(list.hint(for: input, idle: true, bundleId: "com.apple.TextEdit", name: "TextEdit"), "\(input)")
        }
    }

    /// Nothing is turned off until the user turns it off.
    func testNothingIsOffByDefault() {
        XCTAssertEqual(list.apps, [:])
        XCTAssertNil(list.hint(for: .pttDown, idle: true, bundleId: "com.apple.TextEdit", name: "TextEdit"))
    }
}
