import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// Goal rule 3: 🤫 is tiny, sits in the bottom-left corner of the main display, is on top on every Space and
/// over full-screen apps, never takes focus or clicks, and shows at all times. States show at it.
final class IndicatorTests: XCTestCase {
    var made: [Indicator] = []

    override func setUp() {
        _ = NSApplication.shared  // a window needs the app object, even in the test bundle
    }

    override func tearDown() {
        for i in made { i.panel.orderOut(nil) }  // don't leave test panels on screen
    }

    func make() -> Indicator {
        let i = Indicator()
        made.append(i)
        return i
    }

    func testFrameIs18ptAnd8ptFromBottomLeftOfMainScreen() {
        XCTAssertEqual(Indicator.frame(screen: NSRect(x: 0, y: 0, width: 1440, height: 900), labelWidth: nil),
                       NSRect(x: 8, y: 8, width: 18, height: 18))
        // A main display that is not at the origin of the global space (another display left of and above it).
        XCTAssertEqual(Indicator.frame(screen: NSRect(x: -1920, y: -200, width: 1920, height: 1080), labelWidth: nil),
                       NSRect(x: -1912, y: -192, width: 18, height: 18))
    }

    func testLabelGrowsRightwardAndKeepsTheCorner() {
        let frame = Indicator.frame(screen: NSRect(x: 0, y: 0, width: 1440, height: 900), labelWidth: 200)
        XCTAssertEqual(frame.origin, NSPoint(x: 8, y: 8), "the emoji must not move when text shows next to it")
        XCTAssertEqual(frame.height, 18)
        XCTAssertEqual(frame.width, 18 + 6 + 200)
    }

    func testPanelFlags() {
        let panel = make().panel
        // Exact mask: borderless (no title bar, nothing to drag or close) and non-activating (no focus steal).
        XCTAssertEqual(panel.styleMask, [.borderless, .nonactivatingPanel])
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        for flag: NSWindow.CollectionBehavior in [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] {
            XCTAssertTrue(panel.collectionBehavior.contains(flag), "collectionBehavior lacks \(flag.rawValue)")
        }
        XCTAssertTrue(panel.ignoresMouseEvents, "clicks must go to the app under 🤫")
        XCTAssertGreaterThanOrEqual(panel.level.rawValue, NSWindow.Level.statusBar.rawValue, "must sit above the Dock")
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate, "an accessory app is never active, so this would hide 🤫")
        XCTAssertTrue(panel.isVisible, "🤫 shows from launch, idle included")
    }

    func testIdleStaysVisible() {
        let indicator = make()
        indicator.set(.recording)
        indicator.set(.idle)
        XCTAssertTrue(indicator.panel.isVisible)
    }

    func testHintShowsThenHides() {
        let indicator = make()
        indicator.show(Hint.shortPress, seconds: 0.2)
        XCTAssertEqual(indicator.labelText, Hint.shortPress)
        XCTAssertGreaterThan(indicator.panel.frame.width, Indicator.size, "the hint shows next to 🤫")
        XCTAssertEqual(indicator.panel.frame.height, Indicator.size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(indicator.labelText)
        XCTAssertEqual(indicator.panel.frame.width, Indicator.size)
    }

    func testModeRings() throws {
        let indicator = make()
        var colors: [Indicator.Mode: CGColor] = [:]
        for mode: Indicator.Mode in [.recording, .handsFree, .processing, .error] {
            indicator.set(mode)
            let layer = try XCTUnwrap(indicator.emoji.layer)
            XCTAssertEqual(layer.borderWidth, 2, "\(mode)")
            colors[mode] = try XCTUnwrap(layer.borderColor, "\(mode)")
            XCTAssertEqual(layer.animation(forKey: "pulse") != nil, mode == .processing, "only processing pulses: \(mode)")
        }
        let distinct = Set(colors.values.map { $0.components?.map { Int($0 * 255) } ?? [] })
        XCTAssertEqual(distinct.count, 4, "each state needs its own colour")
        indicator.set(.idle)
        XCTAssertEqual(indicator.emoji.layer?.borderWidth, 0)
        XCTAssertNil(indicator.emoji.layer?.animation(forKey: "pulse"))
    }
}
