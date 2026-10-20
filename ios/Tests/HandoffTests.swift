import XCTest
@testable import ShepetalSessionCore

final class HandoffTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let a = UUID(), b = UUID()

    /// Drives one session from the keyboard's request to a ready result.
    func ready(_ id: UUID, text: String, at now: Date) -> Handoff {
        var h = Handoff()
        h.request(id, now: now)
        XCTAssertTrue(h.startRecording(id, now: now))
        XCTAssertTrue(h.finishRecording(id, now: now))
        XCTAssertTrue(h.deliver(id, text: text, now: now))
        return h
    }

    func testHappyPathInsertsTextExactlyOnce() {
        var h = ready(a, text: "hello", at: t0)
        XCTAssertEqual(h.consume(a, now: t0), "hello")
        XCTAssertEqual(h.phase, .inserted)
        // A second keyboard appearance must not paste the same dictation again.
        XCTAssertNil(h.consume(a, now: t0))
    }

    func testResultForAnotherSessionIsNeverInserted() {
        var h = ready(a, text: "old", at: t0)
        // The keyboard only knows its own session; the old text must stay out of the field.
        XCTAssertNil(h.consume(b, now: t0))
        XCTAssertEqual(h.phase, .ready)
    }

    func testLateResultFromSupersededSessionIsRejected() {
        var h = Handoff()
        h.request(a, now: t0)
        h.startRecording(a, now: t0)
        h.finishRecording(a, now: t0)
        // User tapped the mic again before session A finished transcribing.
        h.request(b, now: t0)
        XCTAssertFalse(h.deliver(a, text: "stale", now: t0))
        XCTAssertNil(h.text)
        XCTAssertNil(h.consume(b, now: t0))
        XCTAssertNil(h.consume(a, now: t0))
    }

    func testReadyResultExpiresAfterTimeout() {
        var h = ready(a, text: "late", at: t0)
        XCTAssertNil(h.consume(a, now: t0.addingTimeInterval(Handoff.timeout + 1)))
        XCTAssertEqual(h.phase, .idle)
        XCTAssertNil(h.text)
    }

    func testReadyResultIsInsertedRightAtTheTimeout() {
        var h = ready(a, text: "edge", at: t0)
        XCTAssertEqual(h.consume(a, now: t0.addingTimeInterval(Handoff.timeout)), "edge")
    }

    func testRequestNotPickedUpByAppExpires() {
        var h = Handoff()
        h.request(a, now: t0)
        XCTAssertFalse(h.startRecording(a, now: t0.addingTimeInterval(Handoff.timeout + 1)))
        XCTAssertEqual(h.phase, .idle)
    }

    func testLongRecordingDoesNotExpire() {
        var h = Handoff()
        h.request(a, now: t0)
        h.startRecording(a, now: t0)
        let later = t0.addingTimeInterval(Handoff.timeout * 10)
        XCTAssertTrue(h.finishRecording(a, now: later))
        XCTAssertTrue(h.deliver(a, text: "long", now: later))
        XCTAssertEqual(h.consume(a, now: later), "long")
    }

    func testOutOfOrderTransitionsAreRejected() {
        var h = Handoff()
        XCTAssertFalse(h.startRecording(a, now: t0))
        h.request(a, now: t0)
        XCTAssertFalse(h.deliver(a, text: "skip", now: t0))
        XCTAssertNil(h.consume(a, now: t0))
    }

    func testSurvivesCodableRoundTrip() throws {
        let h = ready(a, text: "persisted", at: t0)
        let decoded = try JSONDecoder().decode(Handoff.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(decoded, h)
    }
}
