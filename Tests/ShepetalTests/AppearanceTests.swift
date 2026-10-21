import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F93: there is no theme picker. Every shepetal window follows System Settings › Appearance (Light, Dark, Auto)
/// live, because none of them pins an appearance or paints a fixed background. Only 🤫 and the meeting card are
/// dark on purpose, so they stay readable on any wallpaper (goal rule 3).
/// NSApp.appearance stands in for the system setting and changes this test process only. Nothing is put on
/// screen, takes focus or touches the clipboard; the Hub gets a temp data dir and a private pasteboard.
@MainActor
final class AppearanceTests: XCTestCase {
    private var root: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        _ = NSApplication.shared  // a window needs the app object, even in the test bundle
        root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        NSApp.appearance = nil
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    /// Building the Hub draws its Home tab, and that reads the account: the keychain item and account.json.
    /// SHEPETAL_HOME and SHEPETAL_KEYCHAIN_SERVICE point both at nothing real first, or the test does not run.
    func testShepetalWindowFollowsTheSystem() throws {
        let saved = ["SHEPETAL_HOME", "SHEPETAL_KEYCHAIN_SERVICE"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer { for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
        setenv("SHEPETAL_HOME", root.path, 1)
        setenv("SHEPETAL_KEYCHAIN_SERVICE", "io.backant.shepetal.test.\(UUID().uuidString)", 1)
        guard Paths.root.path == root.path, TokenStore.keychainService.hasPrefix("io.backant.shepetal.test.") else {
            return XCTFail("an earlier test fixed the data dir, so the Hub would read the real account")
        }
        let hub = Hub(pipeline: try Pipeline(root: root, pasteboard: pasteboard), engine: { nil },
                      status: { ("", false) }, retention: { .keep }, setRetention: { _ in }, openPermissions: {},
                      loginItem: LoginItem(say: { _ in }), openDictionary: {}, restoreFnKey: {})
        let window = try XCTUnwrap(Mirror(reflecting: hub).descendant("window") as? NSWindow,
                                   "Hub's window was renamed: update this test")
        XCTAssertEqual(window.title, "shepetal", "the brand is written in lowercase, the window title too")
        assertFollowsTheSystem(window, "the Shepetal window")
    }

    func testMeetingTranscriptWindowFollowsTheSystem() {
        let w = MeetingTranscriptWindow(model: MeetingsModel(store: InMemoryMeetingStore(), copy: { _ in }), open: { _ in })
        assertFollowsTheSystem(w.panel, "the meeting transcript window")
    }

    func testShortcutsWindowFollowsTheSystem() throws {
        assertFollowsTheSystem(try XCTUnwrap(ShortcutsWindow(tap: FnTap()).window), "the shortcuts window")
    }

    func testPermissionsWindowFollowsTheSystem() throws {
        let w = Onboarding(allowRequests: false, engine: { (false, "") }, loginItem: LoginItem(say: { _ in }))
        assertFollowsTheSystem(try XCTUnwrap(w.window), "the welcome (permissions) window")
    }

    /// A fixed SwiftUI fill leaves every view's appearance alone, so the source is checked too: no forced color
    /// scheme, no pinned appearance and no fixed white, black or RGB background or text colour outside 🤫 and the
    /// meeting card.
    /// ponytail: a line scan, so a fixed colour kept in a variable or an asset catalog passes; the runtime checks
    /// above only draw the Home tab and an empty transcript window, and M-THEME-1 covers the rest by hand.
    func testNoWindowSourceForcesAColorScheme() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Shepetal").standardizedFileURL
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(files.contains("Hub.swift"), dir.path)
        let forced = #"preferredColorScheme|colorScheme\(|\\.colorScheme,|NSAppearance\(named|\.appearance\s*="#
        let fixed = #"(background|foreground|textcolor)[^\n]*(\.white\b|\.black\b|Color\((\.s?rgb|\.displayp3|red|white|hue)|NSColor\((red|white|calibrated|device|srgb|displayp3))"#
        for f in files where !["Indicator.swift", "Meetings/MeetingCard.swift"].contains(f) {
            let code = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                .components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if let r = code.range(of: forced, options: .regularExpression) { XCTFail("\(f) forces light or dark: \(code[r])") }
            if let r = code.range(of: fixed, options: [.regularExpression, .caseInsensitive]) {
                XCTFail("\(f) paints a fixed colour: \(code[r])")
            }
        }
    }

    /// The plate's CGColor is resolved when 🤫 is built, so it is built in Light: a system colour that is dark
    /// only in Dark mode would fail here.
    func testIndicatorStaysDarkInLightMode() throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        let indicator = Indicator(screen: { NSRect(x: 0, y: 0, width: 1440, height: 900) }, present: { _ in })
        XCTAssertFalse(indicator.panel.isVisible, "tests must not put 🤫 on screen")
        let label = try XCTUnwrap(indicator.panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
        assertDarkHUD(label, label.layer?.backgroundColor, "🤫's hint in Light")
    }

    func testMeetingCardStaysDarkInLightMode() throws {
        NSApp.appearance = NSAppearance(named: .aqua)  // built in Light, like 🤫 above
        let card = MeetingCard(screen: { NSRect(x: 0, y: 0, width: 1440, height: 900) }, present: { _ in },
                               onRecord: {}, onNotNow: {})
        XCTAssertFalse(card.panel.isVisible, "tests must not put the card on screen")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: name)
            XCTAssertEqual(card.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
                           "the card's buttons must stay dark in \(name.rawValue)")
            assertDarkHUD(card.label, card.panel.contentView?.layer?.backgroundColor, "the card in \(name.rawValue)")
        }
    }

    // MARK: helpers

    /// Dark, then light, then dark again: the window, every view in it (SwiftUI's too) and its background follow.
    private func assertFollowsTheSystem(_ window: NSWindow, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(window.isVisible, "tests must not put \(name) on screen", file: file, line: line)
        XCTAssertNil(window.appearance, "\(name) pins an appearance, so it ignores System Settings", file: file, line: line)
        for (system, dark) in [(NSAppearance.Name.darkAqua, true), (.aqua, false), (.darkAqua, true)] {
            NSApp.appearance = NSAppearance(named: system)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))  // SwiftUI restyles its views on the next pass
            let want: NSAppearance.Name = dark ? .darkAqua : .aqua
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), want,
                           "\(name) in \(system.rawValue)", file: file, line: line)
            for view in views(window.contentView) {
                XCTAssertEqual(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), want,
                               "\(type(of: view)) in \(name) pins an appearance", file: file, line: line)
            }
            var bg: CGFloat = -1
            window.effectiveAppearance.performAsCurrentDrawingAppearance { bg = Self.luminance(window.backgroundColor.cgColor) }
            XCTAssert(dark ? bg < 0.4 : bg > 0.6, "\(name)'s background is \(bg) in \(system.rawValue)", file: file, line: line)
        }
    }

    /// White text on a near-opaque black plate, whatever the system is set to.
    private func assertDarkHUD(_ label: NSTextField, _ plate: CGColor?, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(label.textColor, .white, "\(name): text", file: file, line: line)
        let plate = plate ?? .clear
        XCTAssertLessThan(Self.luminance(plate), 0.1, "\(name): plate", file: file, line: line)
        XCTAssertGreaterThanOrEqual(plate.alpha, 0.7, "\(name): plate must hide the wallpaper", file: file, line: line)
    }

    private func views(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap(views)
    }

    private static func luminance(_ color: CGColor) -> CGFloat {
        guard let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              c.count >= 3 else { return -1 }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }
}
