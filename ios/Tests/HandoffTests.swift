import XCTest
@testable import ShepetalSessionCore

final class HandoffTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let a = UUID(), b = UUID()
    let field = UUID(), otherField = UUID()

    func recording(_ id: UUID, at now: Date) -> Handoff {
        var h = Handoff()
        h.request(id, document: field, now: now)
        XCTAssertTrue(h.startRecording(id, now: now) {})
        return h
    }

    /// Drives one session from the keyboard's request to a ready result.
    func ready(_ id: UUID, text: String, at now: Date) -> Handoff {
        var h = recording(id, at: now)
        XCTAssertTrue(h.finishRecording(id, now: now))
        XCTAssertTrue(h.deliver(id, text: text, now: now))
        return h
    }

    func testHappyPathInsertsTextExactlyOnce() {
        var h = ready(a, text: "hello", at: t0)
        XCTAssertEqual(h.consume(a, document: field, now: t0), "hello")
        XCTAssertEqual(h.phase, .inserted)
        // A second keyboard appearance must not paste the same dictation again.
        XCTAssertNil(h.consume(a, document: field, now: t0))
    }

    func testResultForAnotherSessionIsNeverInserted() {
        var h = ready(a, text: "old", at: t0)
        // The keyboard only knows its own session; the old text must stay out of the field.
        XCTAssertNil(h.consume(b, document: field, now: t0))
        XCTAssertEqual(h.phase, .ready)
    }

    func testLateResultFromSupersededSessionIsRejected() {
        var h = recording(a, at: t0)
        h.finishRecording(a, now: t0)
        // User tapped the mic again before session A finished transcribing.
        h.request(b, document: field, now: t0)
        XCTAssertFalse(h.deliver(a, text: "stale", now: t0))
        XCTAssertNil(h.text)
        XCTAssertNil(h.consume(b, document: field, now: t0))
        XCTAssertNil(h.consume(a, document: field, now: t0))
    }

    // MARK: Security fix 1: an outside app opening shepetal://dictate must not turn the mic on.

    func testMicDoesNotStartWithoutAKeyboardRequest() {
        var h = Handoff()
        var micStarted = false
        XCTAssertFalse(h.canStart(a, now: t0))
        XCTAssertFalse(h.startRecording(a, now: t0) { micStarted = true })
        XCTAssertFalse(micStarted)
    }

    func testMicDoesNotStartForAGuessedOrWrongSessionID() {
        var h = Handoff()
        h.request(a, document: field, now: t0)
        var micStarted = false
        XCTAssertFalse(h.canStart(b, now: t0))
        XCTAssertFalse(h.startRecording(b, now: t0) { micStarted = true })
        XCTAssertFalse(micStarted)
        XCTAssertEqual(h.phase, .requested)
    }

    func testMicDoesNotStartForAnExpiredRequest() {
        var h = Handoff()
        h.request(a, document: field, now: t0)
        let late = t0.addingTimeInterval(Handoff.timeout + 1)
        var micStarted = false
        XCTAssertFalse(h.canStart(a, now: late))
        XCTAssertFalse(h.startRecording(a, now: late) { micStarted = true })
        XCTAssertFalse(micStarted)
        XCTAssertEqual(h.phase, .idle)
    }

    func testOneRequestStartsTheMicOnlyOnce() {
        var h = Handoff()
        h.request(a, document: field, now: t0)
        var starts = 0
        XCTAssertTrue(h.startRecording(a, now: t0) { starts += 1 })
        // Replaying the same shepetal://dictate URL must not start a second recording.
        XCTAssertFalse(h.startRecording(a, now: t0) { starts += 1 })
        XCTAssertEqual(starts, 1)
    }

    func testFailedMicStartRollsBackToIdle() {
        var h = Handoff()
        h.request(a, document: field, now: t0)
        struct MicError: Error {}
        XCTAssertFalse(h.startRecording(a, now: t0) { throw MicError() })
        XCTAssertEqual(h.phase, .idle)
        XCTAssertFalse(h.shouldKeepRecording(a, now: t0))
    }

    // MARK: Security fix 2: recording is capped and stops when the session is no longer current.

    func testRecordingStopsAtTheFiveMinuteCap() {
        let h = recording(a, at: t0)
        XCTAssertEqual(Handoff.maxRecording, 300)
        XCTAssertTrue(h.shouldKeepRecording(a, now: t0.addingTimeInterval(Handoff.maxRecording - 1)))
        XCTAssertFalse(h.shouldKeepRecording(a, now: t0.addingTimeInterval(Handoff.maxRecording)))
    }

    func testRecordingAtTheCapCanStillBeTranscribed() {
        var h = recording(a, at: t0)
        let atCap = t0.addingTimeInterval(Handoff.maxRecording + 1)
        XCTAssertTrue(h.finishRecording(a, now: atCap))
        XCTAssertTrue(h.deliver(a, text: "long", now: atCap))
        XCTAssertEqual(h.consume(a, document: field, now: atCap), "long")
    }

    func testAbandonedRecordingExpires() {
        var h = recording(a, at: t0)
        let dead = t0.addingTimeInterval(Handoff.maxRecording + Handoff.timeout + 1)
        XCTAssertTrue(h.isExpired(now: dead))
        XCTAssertFalse(h.finishRecording(a, now: dead))
        XCTAssertEqual(h.phase, .idle)
    }

    func testRecordingStopsWhenANewSessionIsRequested() {
        var h = recording(a, at: t0)
        h.request(b, document: field, now: t0)
        XCTAssertFalse(h.shouldKeepRecording(a, now: t0))
    }

    func testRecordingStopsWhenCancelled() {
        var h = recording(a, at: t0)
        XCTAssertTrue(h.cancel(a, now: t0))
        XCTAssertEqual(h.phase, .cancelled)
        XCTAssertFalse(h.shouldKeepRecording(a, now: t0))
        XCTAssertFalse(h.finishRecording(a, now: t0))
    }

    // MARK: Security fix 3: text goes only into the field the dictation started in.

    func testResultForAnotherFieldIsDiscardedNotInserted() {
        var h = ready(a, text: "private", at: t0)
        XCTAssertNil(h.consume(a, document: otherField, now: t0))
        XCTAssertNil(h.text)
        // Discarded for good: going back to the original field must not insert it either.
        XCTAssertNil(h.consume(a, document: field, now: t0))
    }

    // MARK: Timeouts

    func testReadyResultExpiresAfterTimeout() {
        var h = ready(a, text: "late", at: t0)
        XCTAssertNil(h.consume(a, document: field, now: t0.addingTimeInterval(Handoff.timeout + 1)))
        XCTAssertEqual(h.phase, .idle)
        XCTAssertNil(h.text)
    }

    func testReadyResultIsInsertedRightAtTheTimeout() {
        var h = ready(a, text: "edge", at: t0)
        XCTAssertEqual(h.consume(a, document: field, now: t0.addingTimeInterval(Handoff.timeout)), "edge")
    }

    func testOutOfOrderTransitionsAreRejected() {
        var h = Handoff()
        h.request(a, document: field, now: t0)
        XCTAssertFalse(h.deliver(a, text: "skip", now: t0))
        XCTAssertNil(h.consume(a, document: field, now: t0))
    }

    func testSurvivesCodableRoundTrip() throws {
        let h = ready(a, text: "persisted", at: t0)
        let decoded = try JSONDecoder().decode(Handoff.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(decoded, h)
    }
}

// MARK: Requirement 4: the raw audio of every dictation is kept.

final class AudioArchiveTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSavesExactSamplesAsSixteenKilohertzMonoWAVNamedBySession() throws {
        let id = UUID()
        let samples: [Float] = [0, 0.5, -0.25, 1, -1, .leastNonzeroMagnitude]
        let url = try AudioArchive.save(samples, id: id, in: dir)
        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).wav")
        let data = try Data(contentsOf: url)
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u16(_ at: Int) -> UInt16 { data[at..<at + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(u16(20), 3) // IEEE float
        XCTAssertEqual(u16(22), 1) // mono
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u16(34), 32)
        XCTAssertEqual(u32(40), UInt32(samples.count * 4))
        let decoded = (0..<samples.count).map { Float(bitPattern: u32(44 + $0 * 4)) }
        XCTAssertEqual(decoded, samples) // bit-exact, not re-quantized
    }

    func testCancelledSessionKeepsItsAudio() throws {
        let id = UUID()
        var h = Handoff()
        h.request(id, document: UUID())
        h.startRecording(id) {}
        try AudioArchive.cancel(id, samples: [0.1, 0.2], handoff: &h, in: dir)
        XCTAssertEqual(h.phase, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioArchive.url(for: id, in: dir).path))
    }

    func testCancellingAfterTheAudioWasSavedDoesNotDeleteIt() throws {
        let id = UUID()
        var h = Handoff()
        h.request(id, document: UUID())
        h.startRecording(id) {}
        try AudioArchive.save([0.3], id: id, in: dir)
        h.finishRecording(id)
        try AudioArchive.cancel(id, samples: [0.3], handoff: &h, in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioArchive.url(for: id, in: dir).path))
    }

    func testFilesAreWrittenWithCompleteProtection() throws {
        let url = try AudioArchive.save([0], id: UUID(), in: dir)
        let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        // The simulator may not report data protection; on a device this must be .complete.
        if let protection { XCTAssertEqual(protection, .complete) }
    }

    func testDefaultLocationIsTheAppsOwnApplicationSupportNotTheAppGroup() {
        let path = AudioArchive.directory.path
        XCTAssertTrue(path.hasSuffix("Application Support/audio"))
        XCTAssertFalse(path.contains(SharedHandoff.appGroup))
        XCTAssertFalse(path.contains("Shared/AppGroup"))
    }
}
