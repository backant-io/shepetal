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
        var noticePending = false

        init(value: Int?, previous: Int? = nil) { self.value = value; self.previous = previous }

        var io: FnKeySetting.IO {
            FnKeySetting.IO(read: { self.value },
                            write: { self.writes.append($0); if !self.ignoreWrites { self.value = $0 } },
                            restartInputAgents: { self.restarts += 1 },
                            loadPrevious: { self.previous },
                            storePrevious: { self.stores.append($0); self.previous = $0 },
                            takeNoticePending: { defer { self.noticePending = false }; return self.noticePending })
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

    func testInstallerChangeIsAnnouncedOnceAtTheNextLaunch() {
        let f = Fake(value: 0, previous: 1)  // the postinstall already wrote 0 and kept 1
        f.noticePending = true
        let first = FnKeySetting.apply(f.io)
        XCTAssertEqual(first, .changedByInstaller)
        XCTAssertEqual(first.hint, "🌐 key set to Do Nothing so fn can dictate")
        XCTAssertEqual(f.writes, [], "nothing to write: it is already 0")
        XCTAssertEqual(f.restarts, 0)
        XCTAssertFalse(f.noticePending, "the flag is cleared")
        XCTAssertNil(FnKeySetting.apply(f.io).hint, "said once")
    }

    func testDescriptions() {
        XCTAssertEqual(FnKeySetting.describe(1), "Change Input Source")
        XCTAssertEqual(FnKeySetting.describe(0), "Do Nothing")
        XCTAssertEqual(FnKeySetting.describe(FnKeySetting.unset), "the macOS default")
    }
}

/// "fn not received" must mean it: the 🌐 key's 179 reached the tap and fn's 63 did not. Pavel saw it while typing
/// other keys (2026-10-21) because the old check polled the HID fn flag, which macOS also sets for arrows and F-keys.
final class FnHealthTests: XCTestCase {
    /// Polls every 0.1 s from `from` through `to`; returns the times it alerted.
    func alerts(_ h: inout FnHealth, from: TimeInterval, to: TimeInterval) -> [TimeInterval] {
        stride(from: from, through: to, by: 0.1).filter { h.poll(at: $0) }
    }

    func testGlobeWithoutFnAlertsOnceAfterTheWindow() {
        var h = FnHealth()
        h.globe(at: 10)
        XCTAssertEqual(alerts(&h, from: 10, to: 10.9), [], "fn may still come")
        XCTAssertEqual(alerts(&h, from: 11, to: 20), [11], "once per press")
        h.globe(at: 30)
        XCTAssertEqual(alerts(&h, from: 30, to: 32).count, 1, "the next unanswered press alerts again")
    }

    func testGlobeAfterAFnTapNeverAlerts() {
        var h = FnHealth()
        h.fn(down: true, at: 10)
        h.fn(down: false, at: 10.15)
        h.globe(at: 10.16)  // macOS sends the 179 pair right after the release
        XCTAssertEqual(alerts(&h, from: 10, to: 15), [])
    }

    func testFnShortlyAfterTheGlobeCoversIt() {
        var h = FnHealth()
        h.globe(at: 10)  // in case macOS sends 179 before 63
        h.fn(down: true, at: 10.3)
        XCTAssertEqual(alerts(&h, from: 10, to: 15), [])
    }

    func testGlobeWhileFnIsHeldNeverAlerts() {
        var h = FnHealth()
        h.fn(down: true, at: 10)
        h.globe(at: 14)  // 🌐+E during a long hold: the last fn event is 4 s old, but fn is down
        XCTAssertEqual(alerts(&h, from: 14, to: 20), [])
    }

    func testOldFnDoesNotCoverANewGlobe() {
        var h = FnHealth()
        h.fn(down: true, at: 1)
        h.fn(down: false, at: 1.1)
        h.globe(at: 10)
        h.fn(down: true, at: 11.5)  // too late for that press
        XCTAssertEqual(alerts(&h, from: 10, to: 11.4), [11])
    }

    func testNothingButPollsNeverAlerts() {
        var h = FnHealth()
        XCTAssertEqual(alerts(&h, from: 0, to: 60), [])
    }
}
