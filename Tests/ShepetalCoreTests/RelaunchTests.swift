import XCTest
import ShepetalCore

/// F99: a crash reopens the app, but a crash loop must not reopen it forever, and a quit is never a crash.
final class RelaunchTests: XCTestCase {
    func testCrashesBackOffThenGiveUpOnTheFourthInARow() {
        var p = Relaunch()
        XCTAssertEqual(p.exited(clean: false, ran: 300), 1)  // after a long run: the first crash
        XCTAssertEqual(p.exited(clean: false, ran: 5), 2)
        XCTAssertEqual(p.exited(clean: false, ran: 5), 4)
        XCTAssertFalse(p.gaveUp)
        XCTAssertNil(p.exited(clean: false, ran: 5), "four quick crashes in a row: stay down")
        XCTAssertTrue(p.gaveUp)
        XCTAssertEqual(p.crashes, 0, "opened by hand after a give-up, it gets three tries again")
    }

    func testAMinuteOfRunningStartsTheCountAgain() {
        var p = Relaunch(crashes: 3)
        XCTAssertEqual(p.exited(clean: false, ran: Relaunch.resetAfter), 1)
        XCTAssertEqual(p.crashes, 1)
        p = Relaunch(crashes: 3)
        XCTAssertNil(p.exited(clean: false, ran: Relaunch.resetAfter - 1))
        XCTAssertTrue(p.gaveUp)
    }

    func testCleanQuitStaysQuitAndClearsTheCount() {
        var p = Relaunch(crashes: 2)
        XCTAssertNil(p.exited(clean: true, ran: 1))
        XCTAssertEqual(p, Relaunch())
    }

    func testHintIsLowercaseAndPlain() {
        XCTAssertTrue(Relaunch.gaveUpHint.hasPrefix("shepetal "))
    }
}
