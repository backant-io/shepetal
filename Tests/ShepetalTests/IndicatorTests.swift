import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// Goal rule 3: 🤫 is tiny, sits in the bottom-left corner of the main display, is on top on every Space and
/// over full-screen apps, never takes focus or clicks, and shows at all times. States show at it.
/// The panels here are never put on screen: `present` only counts, and the display is a fixed frame.
final class IndicatorTests: XCTestCase {
    var presented = 0

    /// A main display that is not at the origin of the global space, so a frame that ignores it is caught.
    let mainScreen = NSRect(x: 100, y: 50, width: 1440, height: 900)

    override func setUp() {
        _ = NSApplication.shared  // a window needs the app object, even in the test bundle
        presented = 0
    }

    func make(file: StaticString = #filePath, line: UInt = #line) -> Indicator {
        let i = Indicator(screen: { [mainScreen] in mainScreen }, present: { [unowned self] _ in self.presented += 1 })
        XCTAssertFalse(i.panel.isVisible, "tests must not put 🤫 on screen", file: file, line: line)
        return i
    }

    func testFrameIs18ptAnd8ptFromBottomLeftOfMainScreen() {
        XCTAssertEqual(Indicator.frame(screen: NSRect(x: 0, y: 0, width: 1440, height: 900), labelWidth: nil),
                       NSRect(x: 8, y: 8, width: 18, height: 18))
        // A main display that is not at the origin of the global space (another display left of and above it).
        XCTAssertEqual(Indicator.frame(screen: NSRect(x: -1920, y: -200, width: 1920, height: 1080), labelWidth: nil),
                       NSRect(x: -1912, y: -192, width: 18, height: 18))
    }

    func testLivePanelSitsInTheBottomLeftCorner() {
        let indicator = make()
        XCTAssertEqual(indicator.panel.frame, Indicator.frame(screen: mainScreen, labelWidth: nil),
                       "the running 🤫 must be 8 pt in from the bottom-left of the main display")
        XCTAssertEqual(indicator.emoji.frame, NSRect(x: 0, y: 0, width: Indicator.size, height: Indicator.size))
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
    }

    /// 🤫 is presented once at launch and never hidden: no state, hint or hint ending orders it out.
    func testPresentedOnceAndNeverHidden() {
        let indicator = make()
        XCTAssertEqual(presented, 1, "🤫 shows from launch, idle included")
        for mode: Indicator.Mode in [.recording, .idle, .handsFree, .processing, .error, .idle] { indicator.set(mode) }
        indicator.show(Hint.shortPress, seconds: 0.05)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(indicator.labelText)
        XCTAssertEqual(indicator.panel.orderedOut, 0, "🤫 must never be ordered out")
        XCTAssertEqual(presented, 1)
    }

    func testHintShowsThenHides() throws {
        let indicator = make()
        let corner = indicator.panel.frame.origin
        indicator.show(Hint.shortPress, seconds: 0.2)
        XCTAssertEqual(indicator.labelText, Hint.shortPress)
        XCTAssertGreaterThan(indicator.panel.frame.width, Indicator.size, "the hint shows next to 🤫")
        XCTAssertEqual(indicator.panel.frame.height, Indicator.size)
        XCTAssertEqual(indicator.panel.frame.origin, corner, "🤫 must not move when the hint shows")
        let label = try XCTUnwrap(indicator.panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertGreaterThanOrEqual(label.frame.minX, indicator.emoji.frame.maxX, "the hint must not cover 🤫")
        XCTAssertLessThanOrEqual(label.frame.maxX, indicator.panel.frame.width, "the hint must fit in the panel")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(indicator.labelText)
        XCTAssertEqual(indicator.panel.frame, Indicator.frame(screen: mainScreen, labelWidth: nil))
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
