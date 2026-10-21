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

    /// F100: a hint the user missed is kept for the Hub's Recent notices, newest first.
    func testShowKeepsEachNotice() {
        let indicator = make()
        XCTAssertEqual(indicator.notices.newestFirst, [])
        indicator.show(Hint.shortPress, seconds: Hint.seconds)
        indicator.show(PasteGate.focusMoved, seconds: 4)
        XCTAssertEqual(indicator.notices.newestFirst.map(\.text), [PasteGate.focusMoved, Hint.shortPress])
        // SecureInput clears its note with a 0 s show: the notice must keep the time it showed, not when it cleared.
        let kept = indicator.notices.newestFirst
        indicator.show(PasteGate.focusMoved, seconds: 0)
        XCTAssertEqual(indicator.notices.newestFirst, kept)
    }

    /// F100: Recent notices must never hold dictated text. The clipboard hint is checked through the real
    /// Pipeline (temp data dir, private pasteboard) and shown as App.fail shows it.
    @MainActor
    func testClipboardHintKeepsNoDictatedText() async throws {
        let dictated = "meet me at the old pier at nine"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-notice-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let samples = (0..<AudioStore.sampleRate).map { Float(sin(Double($0) * 0.2)) * 0.045 }  // speech level
        let indicator = make()
        for (focusKept, secure) in [(false, nil), (true, "Terminal")] as [(Bool, String?)] {
            let engine = MeetingTranscriberTests.StubEngine()
            engine.texts = [dictated]
            let run = await pipeline.process(samples, engine: engine, context: { ("", "", "") }, focusKept: { focusKept },
                                             secureInput: { secure }, sendPaste: { _ in XCTFail("no Cmd+V") })
            XCTAssertEqual(pasteboard.string(forType: .string)?.contains("old pier"), true, "the text is on the clipboard")
            indicator.show(try XCTUnwrap(run.error), seconds: 4)
        }
        XCTAssertEqual(indicator.notices.newestFirst.map(\.text), [PasteGate.secureInput("Terminal"), PasteGate.focusMoved])
        for n in indicator.notices.newestFirst { XCTAssertFalse(n.text.contains("pier"), n.text) }
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

    /// Pavel's decision (1): the red ring shows the whole time a meeting records, through dictation and errors too.
    func testMeetingKeepsTheRingRedUntilItStops() throws {
        let indicator = make()
        indicator.meeting = true
        let red = NSColor.systemRed.cgColor
        for mode: Indicator.Mode in [.idle, .recording, .handsFree, .processing, .error, .idle] {
            indicator.set(mode)
            let layer = try XCTUnwrap(indicator.emoji.layer)
            XCTAssertEqual(layer.borderWidth, 2, "\(mode)")
            XCTAssertEqual(layer.borderColor, red, "red while the meeting records: \(mode)")
        }
        indicator.set(.error)
        indicator.meeting = false
        XCTAssertNotEqual(indicator.emoji.layer?.borderColor, red, "the dictation state shows again once it stops")
        indicator.set(.idle)
        XCTAssertEqual(indicator.emoji.layer?.borderWidth, 0)
    }
}
