import XCTest
@testable import ShepetalCore

/// F18: the slow notice tells someone who waits that Shepetal is still working. It must not nag: once per
/// dictation, never once the text is ready or the dictation was cancelled, and never when turned off.
final class SlowNoticeTests: XCTestCase {
    @MainActor
    func fired(after seconds: TimeInterval, stopAt stop: TimeInterval? = nil, wait: TimeInterval) async throws -> Int {
        let n = SlowNoticeCount()
        let watch = SlowWatch(after: seconds) { n.value += 1 }
        if let stop {
            try await Task.sleep(nanoseconds: UInt64(stop * 1e9))
            watch.stop()
        }
        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        return n.value
    }

    func testFiresOnceWhenStillRunning() async throws {
        let n = try await fired(after: 0.05, wait: 0.3)
        XCTAssertEqual(n, 1)
    }

    func testAStopBeforeTheThresholdNeverFires() async throws {
        let n = try await fired(after: 0.2, stopAt: 0.02, wait: 0.4)
        XCTAssertEqual(n, 0, "the text was ready in time")
    }

    func testZeroOrLessIsOff() async throws {
        let off = try await fired(after: 0, wait: 0.1)
        let negative = try await fired(after: -1, wait: 0.1)
        XCTAssertEqual(off + negative, 0)
    }

    func testTheThresholdComesFromTheDefaultsKey() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "shepetal-test-\(UUID().uuidString)"))
        XCTAssertEqual(SlowNotice.seconds(d), 3, "unset is about 3 s")
        d.set(0.1, forKey: SlowNotice.key)
        XCTAssertEqual(SlowNotice.seconds(d), 0.1)
        d.set(0, forKey: SlowNotice.key)
        XCTAssertEqual(SlowNotice.seconds(d), 0, "0 turns it off, it does not fall back to 3 s")
    }
}

@MainActor
final class SlowNoticeCount { var value = 0 }
