import AppKit
import ShepetalCore
import XCTest
@testable import Shepetal

/// Pavel, 22.10.26: "A new version of shepetal is ready. Install now?", never while recording or dictating, and it
/// installs and relaunches only on yes. `UpdatePrompt` decides when the card is up, `MeetingCard.update` is the card,
/// and `SparkleUpdater` (Sparkle itself cannot run here) is pinned by its source.
final class UpdatePromptTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let quiet = UpdateGate.quiet

    private func found(manual: Bool) -> UpdatePrompt {
        var p = UpdatePrompt()
        p.version = "0.2.1"
        p.found = t0
        p.manual = manual
        return p
    }

    func testAFindWhileShepetalWorksStaysHidden() {
        let works = [Activity(dictating: true), Activity(meeting: true), Activity(retranscribing: true)]
        for manual in [false, true] {
            for var a in works {
                a.lastFnPress = t0 - 2 * quiet  // fn long quiet: only the work holds the card
                var p = found(manual: manual)
                XCTAssertFalse(p.update(a, now: t0), "never while \(a.work!), manual \(manual)")
                XCTAssertFalse(p.showing)
            }
        }
        var nothing = UpdatePrompt()
        XCTAssertFalse(nothing.update(Activity(), now: t0), "no card without a found update")
    }

    func testAManualCheckAsksOnceTheWorkEnds() {
        var p = found(manual: true)
        XCTAssertFalse(p.update(Activity(dictating: true, lastFnPress: t0), now: t0))
        XCTAssertTrue(p.update(Activity(lastFnPress: t0), now: t0 + 1), "Check for Updates… does not wait 20 minutes")
    }

    func testAScheduledCheckAsksOnlyTwentyMinutesAfterTheLastFnPress() {
        var p = found(manual: false)
        XCTAssertFalse(p.update(Activity(dictating: true, lastFnPress: t0), now: t0))
        XCTAssertFalse(p.update(Activity(lastFnPress: t0), now: t0 + quiet - 1))
        XCTAssertTrue(p.update(Activity(lastFnPress: t0), now: t0 + quiet))
        var fresh = found(manual: false)
        XCTAssertTrue(fresh.update(Activity(), now: t0), "no fn press since launch is quiet")
    }

    func testWorkTakesTheCardDownAndItComesBackOnlyWhenQuietAgain() {
        var p = found(manual: false)
        XCTAssertTrue(p.update(Activity(lastFnPress: t0 - quiet), now: t0))
        XCTAssertTrue(p.update(Activity(lastFnPress: t0 + 5), now: t0 + 6), "an up card stays while nothing works")
        XCTAssertFalse(p.update(Activity(dictating: true, lastFnPress: t0 + 10), now: t0 + 11), "down when a dictation starts")
        XCTAssertFalse(p.update(Activity(lastFnPress: t0 + 10), now: t0 + 30), "a scheduled find waits for fn's quiet again")
        XCTAssertFalse(p.update(Activity(lastFnPress: t0 + 10), now: t0 + 10 + quiet - 1))
        XCTAssertTrue(p.update(Activity(lastFnPress: t0 + 10), now: t0 + 10 + quiet))

        var m = found(manual: true)
        XCTAssertTrue(m.update(Activity(lastFnPress: t0), now: t0))
        XCTAssertFalse(m.update(Activity(meeting: true, lastFnPress: t0), now: t0 + 60), "down while a meeting records")
        XCTAssertTrue(m.update(Activity(lastFnPress: t0), now: t0 + 61), "a manual find is back when the meeting ends")
    }

    func testADayOldFindExpires() {
        XCTAssertFalse(UpdatePrompt().expired(now: t0), "nothing found, nothing to expire")
        let p = found(manual: false)
        XCTAssertFalse(p.expired(now: t0 + 86_400))
        XCTAssertTrue(p.expired(now: t0 + 86_401))
    }

    // MARK: the card

    let mainScreen = NSRect(x: 100, y: 50, width: 1440, height: 900)

    @MainActor
    func testTheCardAsksWithInstallNowAndLater() {
        _ = NSApplication.shared
        var clicks: [String] = []
        let c = MeetingCard.update(screen: { [mainScreen] in mainScreen }, present: { _ in },
                                   onInstall: { clicks.append("install") }, onLater: { clicks.append("later") })
        c.show("0.2.1")
        XCTAssertEqual(c.label.stringValue, "A new version of shepetal is ready. Install now?")
        XCTAssertEqual(c.record.title, "Install Now")
        XCTAssertEqual(c.notNow.title, "Later")
        c.record.performClick(nil)
        c.notNow.performClick(nil)
        XCTAssertEqual(clicks, ["install", "later"])
    }

    /// Like the meeting card: it takes the click without taking focus from the app Shepetal pastes into, and it sits
    /// one row higher, so both can be up at once and Record stays clickable.
    @MainActor
    func testTheCardNeverTakesFocusAndSitsAboveTheMeetingCard() {
        _ = NSApplication.shared
        var presented = 0
        let u = MeetingCard.update(screen: { [mainScreen] in mainScreen }, present: { _ in presented += 1 },
                                   onInstall: {}, onLater: {})
        let m = MeetingCard(screen: { [mainScreen] in mainScreen }, present: { _ in }, onRecord: {}, onNotNow: {})
        u.show("0.2.1")
        m.show("Zoom")
        XCTAssertEqual(presented, 1)
        XCTAssertFalse(u.panel.isVisible, "tests must not put the card on screen")
        XCTAssertTrue(u.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(u.panel.canBecomeKey, "typing keeps going to the app you are in")
        XCTAssertFalse(u.panel.ignoresMouseEvents, "the card takes clicks")

        let up = u.panel.frame, meeting = m.panel.frame
        XCTAssertEqual(up.minX, meeting.minX, "left edges line up with 🤫")
        XCTAssertEqual(up.minY, meeting.maxY + Indicator.labelGap, accuracy: 0.5, "one row above the meeting card")
        XCTAssertFalse(up.intersects(meeting))
        XCTAssertFalse(up.intersects(Indicator.frame(screen: mainScreen, labelWidth: 400)), "🤫 and its hint stay visible")
        XCTAssertLessThan(up.width, 600)
        u.panel.contentView?.layoutSubtreeIfNeeded()
        for v in [u.label, u.record, u.notNow] as [NSView] {
            XCTAssertTrue(u.panel.contentView!.bounds.contains(v.frame), "\(v) fits on the card")
        }
        u.show(nil)
        XCTAssertEqual(presented, 1)
    }

    // MARK: the wiring, by its source

    /// One `SparkleUpdater` method, line for line. Sparkle drives these and a test cannot: `SPUUserUpdateState` has
    /// no initializer. So, like `menuNeedsUpdate` in MenuModelTests, a changed, added or removed line fails.
    private func lines(of method: String) throws -> [String] {
        let body = try AppSource.body(of: "final class SparkleUpdater", in: AppSource.code("Install.swift"))
        let start = try XCTUnwrap(body.range(of: method), method)
        let rest = body[start.upperBound...]
        return rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)]
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func testSparkleNeverInstallsWithoutAYes() throws {
        let body = try AppSource.body(of: "final class SparkleUpdater", in: AppSource.code("Install.swift"))
        // The only yes: Install Now, and Sparkle's last question, which comes only after Install Now.
        XCTAssertEqual(body.components(separatedBy: .newlines).filter { $0.contains(".install") }
            .map { $0.trimmingCharacters(in: .whitespaces) }, [
            "private lazy var card = MeetingCard.update(onInstall: { [weak self] in self?.answer(.install) },",
            "func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }",
        ])
        XCTAssertTrue(body.contains("onLater: { [weak self] in self?.answer(.dismiss) }"), "Later only dismisses")
        // A found update only waits for the card: no answer here. A scheduled find stays scheduled, so it waits for
        // fn's 20 quiet minutes.
        XCTAssertEqual(try lines(of: "func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,"), [
            "reply: @escaping (SPUUserUpdateChoice) -> Void) {",
            "guard !appcastItem.isInformationOnlyUpdate else { return reply(.dismiss) }",
            "prompt.version = appcastItem.displayVersionString",
            "prompt.found = Date()",
            "prompt.manual = state.userInitiated",
            "self.reply = reply",
            "tick()",
        ])
        // The card's choice goes to Sparkle once, and the card is down before it does.
        XCTAssertEqual(try lines(of: "private func answer(_ choice: SPUUserUpdateChoice) {"), [
            "prompt = UpdatePrompt()",
            "card.show(nil)",
            "let r = reply",
            "reply = nil",
            "r?(choice)",
        ])
        for never in [".skip", "SPUStandardUpdaterController", "runModal", "activate(", "willInstallUpdateOnQuit"] {
            XCTAssertFalse(body.contains(never), "SparkleUpdater uses \(never)")
        }
        XCTAssertTrue(body.contains("Timer.scheduledTimer(withTimeInterval: 1,"), "the card goes down within a second of work")

        let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/make-app.sh").standardizedFileURL, encoding: .utf8)
        XCTAssertTrue(script.contains("<key>SUAllowsAutomaticUpdates</key><false/>"), "nothing downloads or installs on quit by itself")
        XCTAssertFalse(script.contains("SUAutomaticallyUpdate"))

        let settings = try AppSource.body(of: "private struct SettingsTab", in: AppSource.code("Hub.swift"))
        XCTAssertFalse(settings.contains("Install updates automatically"))
    }

    /// The card is exactly what `UpdatePrompt` says, every second: down during any work, back only when the gate
    /// allows it, and a day-old find answered Later. The relaunch after Install Now waits for the work to end.
    func testTheCardFollowsUpdatePromptEverySecond() throws {
        XCTAssertEqual(try lines(of: "private func tick() {"), [
            "let now = Date(), a = activity()",
            "if prompt.expired(now: now) { answer(.dismiss) }",
            "let was = prompt.showing",
            "if prompt.update(a, now: now) != was { card.show(prompt.showing ? prompt.version : nil) }",
            "if let go = relaunch, UpdateGate.allows(a, now: now, manual: true) { relaunch = nil; go() }",
        ])
        // Check for Updates… while a find waits makes it manual: the card as soon as the work ends.
        XCTAssertEqual(try lines(of: "func showUpdateInFocus() {"), ["prompt.manual = true", "tick()"])
        // Sparkle ended the session: nothing waits, so no card and no answer left to give.
        XCTAssertEqual(try lines(of: "func dismissUpdateInstallation() {"), ["prompt = UpdatePrompt()", "reply = nil", "card.show(nil)"])
    }
}
