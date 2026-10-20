import AppKit
import XCTest
@testable import Shepetal

/// Pavel's decision (1): a detected meeting records only after one click on Record, unless "Always record
/// meetings automatically" is on. Recording other people without that click is what §201 StGB forbids.
final class MeetingOfferTests: XCTestCase {
    enum Event: CaseIterable { case zoom, teams, notNow, tick10, tick25, zoomEnded }

    private func run(_ e: Event, _ o: inout MeetingOffer, _ now: inout Double, auto: Bool = false) -> MeetingOffer.Step {
        switch e {
        case .zoom: return o.detected("Zoom", autoRecord: auto, now: now)
        case .teams: return o.detected("Microsoft Teams", autoRecord: auto, now: now)
        case .notNow: return o.notNow()
        case .tick10: now += 10; return o.tick(now: now)
        case .tick25: now += 25; return o.tick(now: now)
        case .zoomEnded: return o.ended("Zoom")
        }
    }

    /// Every sequence of up to five detector, button and clock events without a Record click: none records.
    func testNothingRecordsWithoutTheClickWhileTheSettingIsOff() {
        var sequences: [[Event]] = [[]]
        for _ in 0..<5 { sequences = sequences.flatMap { s in Event.allCases.map { s + [$0] } } }
        XCTAssertEqual(sequences.count, 7776)
        for s in sequences {
            var o = MeetingOffer()
            var now = 0.0
            for e in s {
                if case .record = run(e, &o, &now) { return XCTFail("recorded without a click: \(s)") }
            }
        }
    }

    func testOneClickRecordsTheOfferedMeetingOnce() {
        var o = MeetingOffer()
        XCTAssertEqual(o.detected("Zoom", autoRecord: false, now: 0), .offer("Zoom"))
        XCTAssertEqual(o.app, "Zoom")
        XCTAssertEqual(o.record(), .record("Zoom"))
        XCTAssertNil(o.app, "the card goes")
        XCTAssertEqual(o.record(), .none, "a second click records nothing more")
        XCTAssertEqual(o.tick(now: 100), .none)
    }

    func testNotNowAndTheTimeoutStartNothing() {
        var o = MeetingOffer()
        _ = o.detected("Zoom", autoRecord: false, now: 0)
        XCTAssertEqual(o.notNow(), .dismiss)
        XCTAssertEqual(o.record(), .none, "a click after Not now")
        XCTAssertEqual(o.notNow(), .none)

        _ = o.detected("Zoom", autoRecord: false, now: 100)
        XCTAssertEqual(o.tick(now: 119.9), .none, "up for 20 s")
        XCTAssertEqual(o.tick(now: 120), .dismiss)
        XCTAssertEqual(o.record(), .none, "a click after the timeout")
    }

    func testOfferedMeetingThatEndsTakesTheCardAway() {
        var o = MeetingOffer()
        _ = o.detected("Zoom", autoRecord: false, now: 0)
        XCTAssertEqual(o.ended("Microsoft Teams"), .none, "another meeting ending leaves the card")
        XCTAssertEqual(o.ended("Zoom"), .dismiss)
        XCTAssertEqual(o.record(), .none)
    }

    func testANewerMeetingReplacesTheCardAndRestartsItsClock() {
        var o = MeetingOffer()
        _ = o.detected("Zoom", autoRecord: false, now: 0)
        XCTAssertEqual(o.detected("Microsoft Teams", autoRecord: false, now: 15), .offer("Microsoft Teams"))
        XCTAssertEqual(o.tick(now: 30), .none)
        XCTAssertEqual(o.record(), .record("Microsoft Teams"))
    }

    func testAlwaysRecordStartsAtOnceWithoutACard() {
        var o = MeetingOffer()
        XCTAssertEqual(o.detected("Zoom", autoRecord: true, now: 0), .record("Zoom"))
        XCTAssertNil(o.app)
        XCTAssertEqual(o.tick(now: 30), .none)
    }

    // MARK: the card

    let mainScreen = NSRect(x: 100, y: 50, width: 1440, height: 900)

    @MainActor
    private func card(_ clicks: @escaping (String) -> Void = { _ in }, presented: @escaping () -> Void = {}) -> MeetingCard {
        _ = NSApplication.shared
        return MeetingCard(screen: { [mainScreen] in mainScreen }, present: { _ in presented() },
                           onRecord: { clicks("record") }, onNotNow: { clicks("notNow") })
    }

    @MainActor
    func testCardSitsJustAboveTheIndicatorAndNeverCoversIt() {
        var presented = 0
        let c = card(presented: { presented += 1 })
        c.show("Zoom")
        XCTAssertEqual(presented, 1)
        XCTAssertFalse(c.panel.isVisible, "tests must not put the card on screen")
        XCTAssertEqual(c.label.stringValue, "Meeting detected · Zoom")
        XCTAssertEqual(c.app, "Zoom")

        let f = c.panel.frame
        let shush = Indicator.frame(screen: mainScreen, labelWidth: nil)
        XCTAssertEqual(f, MeetingCard.frame(screen: mainScreen, size: f.size))
        XCTAssertEqual(f.minX, shush.minX, "left edge lines up with 🤫")
        XCTAssertEqual(f.minY, shush.maxY + Indicator.labelGap, "just above 🤫")
        XCTAssertFalse(f.intersects(Indicator.frame(screen: mainScreen, labelWidth: 400)), "🤫 and its hint stay visible")
        XCTAssertLessThan(f.height, 40, "a small card")
        XCTAssertGreaterThan(f.width, 150, "room for the text and both buttons")
        XCTAssertLessThan(f.width, 500)
        c.panel.contentView?.layoutSubtreeIfNeeded()
        for v in [c.label, c.record, c.notNow] as [NSView] {
            XCTAssertTrue(c.panel.contentView!.bounds.contains(v.frame), "\(v) fits on the card \(v.frame) in \(c.panel.contentView!.bounds)")
        }

        c.show(nil)
        XCTAssertNil(c.app)
        XCTAssertEqual(presented, 1)
    }

    /// Clickable, unlike 🤫, but never takes focus: borderless and non-activating, so it cannot become key.
    @MainActor
    func testCardTakesClicksWithoutTakingFocus() {
        var clicks: [String] = []
        let c = card { clicks.append($0) }
        let p = c.panel
        XCTAssertEqual(p.styleMask, [.borderless, .nonactivatingPanel])
        XCTAssertFalse(p.ignoresMouseEvents, "the card takes clicks")
        XCTAssertFalse(p.canBecomeKey, "typing keeps going to the app you are in")
        XCTAssertFalse(p.canBecomeMain)
        XCTAssertFalse(p.hidesOnDeactivate, "an accessory app is never active, so this would hide the card")
        XCTAssertGreaterThanOrEqual(p.level.rawValue, NSWindow.Level.statusBar.rawValue, "above the Dock, like 🤫")
        for flag: NSWindow.CollectionBehavior in [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] {
            XCTAssertTrue(p.collectionBehavior.contains(flag), "collectionBehavior lacks \(flag.rawValue)")
        }
        XCTAssertEqual(c.record.title, "Record")
        XCTAssertEqual(c.notNow.title, "Not now")
        for b in [c.record, c.notNow] {
            XCTAssertTrue(b.acceptsFirstMouse(for: nil), "the first click on a panel that is not key must land")
        }
        c.record.performClick(nil)
        c.notNow.performClick(nil)
        XCTAssertEqual(clicks, ["record", "notNow"])

        XCTAssertTrue(Indicator(screen: { .zero }, present: { _ in }).panel.ignoresMouseEvents, "🤫 itself stays click-through")
    }
}
