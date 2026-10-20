import XCTest
@testable import ShepetalCore

/// The 🌐 key logic with fake defaults and a fake process killer: the real setting is never read or written.
final class FnKeySettingTests: XCTestCase {
    final class Fake {
        var value: Int?
        var previous: Int?
        var writes: [Int?] = []
        var restarts = 0
        var stores: [Int?] = []
        var ignoreWrites = false

        init(value: Int?, previous: Int? = nil) { self.value = value; self.previous = previous }

        var io: FnKeySetting.IO {
            FnKeySetting.IO(read: { self.value },
                            write: { self.writes.append($0); if !self.ignoreWrites { self.value = $0 } },
                            restartInputAgents: { self.restarts += 1 },
                            loadPrevious: { self.previous },
                            storePrevious: { self.stores.append($0); self.previous = $0 })
        }
    }

    func testAlreadyDoNothingWritesNothingAndStaysSilent() {
        let f = Fake(value: 0)
        let outcome = FnKeySetting.apply(f.io)
        XCTAssertEqual(outcome, .alreadySet)
        XCTAssertNil(outcome.hint)
        XCTAssertEqual(f.writes, [])
        XCTAssertEqual(f.restarts, 0)
        XCTAssertEqual(f.stores, [])
    }

    func testChangeInputSourceIsSetToDoNothingAndSaysSo() {
        let f = Fake(value: 1)
        let outcome = FnKeySetting.apply(f.io)
        XCTAssertEqual(outcome, .changed(from: 1))
        XCTAssertEqual(outcome.hint, "🌐 key set to Do Nothing so fn can dictate")
        XCTAssertEqual(f.writes, [0])
        XCTAssertEqual(f.restarts, 1, "TextInputMenuAgent and TextInputSwitcher must restart so it applies without a logout")
        XCTAssertEqual(f.previous, 1)
    }

    func testEmojiAndDictationAreChangedToo() {
        for v in [2, 3] {
            let f = Fake(value: v)
            XCTAssertEqual(FnKeySetting.apply(f.io), .changed(from: v))
            XCTAssertEqual(f.value, 0)
        }
    }

    func testAbsentKeyIsChangedAndRememberedAsUnset() {
        let f = Fake(value: nil)
        XCTAssertEqual(FnKeySetting.apply(f.io), .changed(from: nil))
        XCTAssertEqual(f.previous, FnKeySetting.unset)
        XCTAssertTrue(FnKeySetting.restore(f.io))
        XCTAssertNil(f.value, "restoring an absent key deletes it")
    }

    func testPreviousValueIsStoredOnlyOnce() {
        let f = Fake(value: 2)
        _ = FnKeySetting.apply(f.io)
        f.value = 1  // the user changed it again in System Settings
        _ = FnKeySetting.apply(f.io)
        XCTAssertEqual(f.stores, [2], "the first replaced value is kept")
        XCTAssertEqual(f.previous, 2)
        XCTAssertEqual(f.writes, [0, 0])
    }

    func testSecondLaunchIsSilent() {
        let f = Fake(value: 1)
        XCTAssertNotNil(FnKeySetting.apply(f.io).hint)
        XCTAssertNil(FnKeySetting.apply(f.io).hint)
        XCTAssertEqual(f.restarts, 1)
    }

    func testWriteThatDoesNotStickIsReported() {
        let f = Fake(value: 1)
        f.ignoreWrites = true
        let outcome = FnKeySetting.apply(f.io)
        XCTAssertEqual(outcome, .failed(readBack: 1))
        XCTAssertEqual(outcome.hint, "Set Press 🌐 key to Do Nothing")
    }

    func testRestorePutsBackTheOldValueOnceAndForgetsIt() {
        let f = Fake(value: 1)
        _ = FnKeySetting.apply(f.io)
        XCTAssertEqual(FnKeySetting.restorable(f.io), 1)
        XCTAssertTrue(FnKeySetting.restore(f.io))
        XCTAssertEqual(f.value, 1)
        XCTAssertNil(f.previous)
        XCTAssertEqual(f.restarts, 2)
        XCTAssertFalse(FnKeySetting.restore(f.io), "nothing left to restore")
        XCTAssertNil(FnKeySetting.restorable(f.io))
    }

    func testRestoreWithoutAChangeDoesNothing() {
        let f = Fake(value: 0)
        XCTAssertFalse(FnKeySetting.restore(f.io))
        XCTAssertEqual(f.writes, [])
        XCTAssertEqual(f.restarts, 0)
    }

    func testDescriptions() {
        XCTAssertEqual(FnKeySetting.describe(1), "Change Input Source")
        XCTAssertEqual(FnKeySetting.describe(0), "Do Nothing")
        XCTAssertEqual(FnKeySetting.describe(FnKeySetting.unset), "the macOS default")
    }
}

final class FnHealthTests: XCTestCase {
    func testPressTheTapNeverReportsAlertsOnceAfterGrace() {
        var h = FnHealth()
        XCTAssertFalse(h.poll(hidFnDown: true, at: 10))
        XCTAssertFalse(h.poll(hidFnDown: true, at: 10.5))
        XCTAssertTrue(h.poll(hidFnDown: true, at: 11.0))
        XCTAssertFalse(h.poll(hidFnDown: true, at: 11.5), "once per press")
        XCTAssertFalse(h.poll(hidFnDown: false, at: 12))
        XCTAssertFalse(h.poll(hidFnDown: true, at: 13))
        XCTAssertTrue(h.poll(hidFnDown: true, at: 14.1), "the next unreported press alerts again")
    }

    func testReportedPressNeverAlerts() {
        var h = FnHealth()
        h.tapEvent(at: 10.02)
        for t in stride(from: 10.0, through: 13.0, by: 0.1) { XCTAssertFalse(h.poll(hidFnDown: true, at: t)) }
    }

    func testTapEventJustBeforeThePollCounts() {
        var h = FnHealth()
        h.tapEvent(at: 9.8)  // the tap saw fn down before the 0.1 s poll did
        for t in stride(from: 10.0, through: 12.0, by: 0.1) { XCTAssertFalse(h.poll(hidFnDown: true, at: t)) }
    }

    func testOldTapEventDoesNotCoverANewPress() {
        var h = FnHealth()
        h.tapEvent(at: 1)
        XCTAssertFalse(h.poll(hidFnDown: true, at: 10))
        XCTAssertTrue(h.poll(hidFnDown: true, at: 11))
    }

    func testShortPressDoesNotAlert() {
        var h = FnHealth()
        XCTAssertFalse(h.poll(hidFnDown: true, at: 10))
        XCTAssertFalse(h.poll(hidFnDown: true, at: 10.3))
        XCTAssertFalse(h.poll(hidFnDown: false, at: 10.4))
    }
}
