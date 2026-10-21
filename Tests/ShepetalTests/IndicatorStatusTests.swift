import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F114 creator mode: a label that stays next to 🤫 while recording, so a screen recording shows when the
/// speaker dictates. Rule 3 still holds with it: 🤫 does not move, the panel only grows rightward, clicks go through.
extension IndicatorTests {
    func testStatusStaysWhileSetAndKeepsTheCorner() throws {
        let indicator = make()
        let corner = indicator.panel.frame.origin
        indicator.set(.recording)
        indicator.status = Indicator.creatorLabel
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(indicator.labelText, Indicator.creatorLabel, "the label stays, it is not a timed hint")
        indicator.set(.handsFree)
        XCTAssertEqual(indicator.labelText, Indicator.creatorLabel, "hands-free is still recording")

        let label = try XCTUnwrap(indicator.panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
        let expected = Indicator.frame(screen: mainScreen, labelWidth: label.frame.width)
        XCTAssertEqual(indicator.panel.frame.origin, corner, "🤫 must not move when the label shows")
        XCTAssertEqual(indicator.panel.frame.origin, expected.origin)
        XCTAssertEqual(indicator.panel.frame.height, Indicator.size)
        XCTAssertEqual(indicator.panel.frame.width, expected.width, accuracy: 1, "the panel grows rightward to fit the label")
        XCTAssertGreaterThanOrEqual(label.frame.minX, indicator.emoji.frame.maxX, "the label must not cover 🤫")
        XCTAssertTrue(indicator.panel.ignoresMouseEvents, "clicks must still go to the app under 🤫")
        XCTAssertEqual(indicator.panel.orderedOut, 0)
    }

    /// The 1-minute warning or "Still transcribing" must still be readable in creator mode.
    func testHintCoversStatusThenStatusReturns() {
        let indicator = make()
        indicator.set(.recording)
        indicator.status = Indicator.creatorLabel
        indicator.show(Hint.oneMinuteLeft, seconds: 0.1)
        XCTAssertEqual(indicator.labelText, Hint.oneMinuteLeft)
        indicator.status = "changed"
        XCTAssertEqual(indicator.labelText, Hint.oneMinuteLeft, "a new status waits for the hint to end")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(indicator.labelText, "changed", "the label comes back after the hint")
    }

    /// Release, Esc, too short, a mic end or an error: the label must not stay on screen after the dictation.
    func testStatusClearsWhenTheDictationEnds() {
        let indicator = make()
        for end: Indicator.Mode in [.processing, .idle, .error] {
            indicator.set(.recording)
            indicator.status = Indicator.creatorLabel
            indicator.set(end)
            XCTAssertNil(indicator.status, "\(end)")
            XCTAssertNil(indicator.labelText, "\(end)")
            XCTAssertEqual(indicator.panel.frame, Indicator.frame(screen: mainScreen, labelWidth: nil), "\(end)")
        }
        indicator.set(.recording)
        indicator.status = Indicator.creatorLabel
        indicator.show(Hint.shortPress, seconds: 0.05)
        indicator.set(.idle)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(indicator.labelText, "a hint that ends after the dictation does not bring the label back")
    }

    /// Off unless turned on in Settings, and the label says "shepetal" in lowercase.
    func testCreatorModeIsOffByDefault() throws {
        let name = "shepetal-creator-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(Indicator.creatorStatus(defaults))
        defaults.set(true, forKey: "creatorMode")
        XCTAssertEqual(Indicator.creatorStatus(defaults), "Dictating with shepetal")
        defaults.set(false, forKey: "creatorMode")
        XCTAssertNil(Indicator.creatorStatus(defaults))
    }
}
