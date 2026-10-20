import UIKit
import UniformTypeIdentifiers
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
        XCTAssertEqual(h.consume(a, document: field, now: t0), .insert("hello"))
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

    func testFailedMicStartEndsTheSessionAndTellsTheKeyboard() {
        var h = Handoff()
        h.request(a, document: field, now: t0)
        struct MicError: Error {}
        XCTAssertFalse(h.startRecording(a, now: t0) { throw MicError() })
        XCTAssertEqual(h.phase, .failed)
        XCTAssertFalse(h.shouldKeepRecording(a, now: t0))
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0)?.hasPrefix("Could not start the microphone"), true)
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
        XCTAssertEqual(h.consume(a, document: field, now: atCap), .insert("long"))
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

    // MARK: Security fix 3 and goal rule 8: text is inserted only into the field the dictation started in.
    // A result for a different field goes to the clipboard instead of being discarded.

    func testResultForAnotherFieldIsCopiedNotInserted() {
        var h = ready(a, text: "private", at: t0)
        XCTAssertEqual(h.consume(a, document: otherField, now: t0), .copy("private"))
        XCTAssertNil(h.text)
        // The hint says to paste, without an error ring: the text was not lost.
        XCTAssertEqual(h.phase, .inserted)
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0)?.contains("clipboard"), true)
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0)?.contains("Paste"), true)
        XCTAssertEqual(h.indicatorMode(for: a, now: t0), .idle)
        // Delivered once: going back to the original field must not insert it as well.
        XCTAssertNil(h.consume(a, document: field, now: t0))
    }

    func testClipboardWriteThatDidNotLandSaysTheTextIsInHistory() {
        var h = ready(a, text: "private", at: t0)
        XCTAssertEqual(h.consume(a, document: otherField, now: t0), .copy("private"))
        XCTAssertFalse(h.copyFailed(b, now: t0)) // another session's failure changes nothing
        XCTAssertTrue(h.copyFailed(a, now: t0))
        XCTAssertEqual(h.phase, .failed)
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0)?.contains("history"), true)
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0)?.contains("clipboard"), false) // no wrong paste hint
        XCTAssertEqual(h.indicatorMode(for: a, now: t0), .error)
        XCTAssertFalse(h.copyFailed(a, now: t0)) // once
        XCTAssertNil(h.consume(a, document: field, now: t0))
    }

    func testCopyHintKeepsTheNoteDeliveredWithTheText() {
        var h = Handoff()
        h.request(a, document: field, now: t0)
        h.startRecording(a, now: t0) {}
        h.finishRecording(a, now: t0)
        h.deliver(a, text: "long", note: "Stopped at the 5-minute limit.", now: t0)
        XCTAssertEqual(h.consume(a, document: otherField, now: t0), .copy("long"))
        let status = h.keyboardStatus(for: a, now: t0) ?? ""
        XCTAssertTrue(status.contains("clipboard"))
        XCTAssertTrue(status.hasSuffix("Stopped at the 5-minute limit."))
    }

    func testResultForTheSameFieldIsInserted() {
        var h = ready(a, text: "hi", at: t0)
        XCTAssertEqual(h.consume(a, document: field, now: t0), .insert("hi"))
    }

    func testCopyLeavesThePlainTextOnThePasteboardWithoutRestoringTheOldOne() throws {
        // A private named pasteboard: tests never touch the user's clipboard.
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("io.backant.shepetal.tests.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: board.name) }
        board.string = "old clipboard"
        XCTAssertTrue(Clipboard.copy("dictated text", to: board)) // the write is checked
        XCTAssertEqual(board.string, "dictated text")
        XCTAssertEqual(board.numberOfItems, 1)
        XCTAssertTrue(board.contains(pasteboardTypes: [UTType.utf8PlainText.identifier]))
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
        XCTAssertEqual(h.consume(a, document: field, now: t0.addingTimeInterval(Handoff.timeout)), .insert("edge"))
    }

    // MARK: The keyboard is told how every dictation ended (product rule 3: errors show at the indicator).

    func testKeyboardShowsWhyADictationFailed() {
        var h = recording(a, at: t0)
        h.finishRecording(a, now: t0)
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0), "Transcribing...")
        XCTAssertTrue(h.fail(a, "Could not transcribe: bad audio", now: t0))
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0), "Could not transcribe: bad audio")
        XCTAssertNil(h.consume(a, document: field, now: t0))
    }

    func testKeyboardShowsCancelledAndTimedOutSessions() {
        var h = recording(a, at: t0)
        h.cancel(a, now: t0)
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0)?.hasPrefix("Cancelled"), true)
        let stuck = ready(a, text: "late", at: t0)
        XCTAssertEqual(stuck.keyboardStatus(for: a, now: t0.addingTimeInterval(Handoff.timeout + 1))?.contains("timed out"), true)
        // A session the keyboard no longer knows about says nothing.
        XCTAssertNil(stuck.keyboardStatus(for: nil, now: t0))
    }

    func testNoteOnDeliveredTextStaysAfterInsertion() {
        var h = recording(a, at: t0)
        h.finishRecording(a, now: t0)
        h.deliver(a, text: "partial", note: "Recording stopped early", now: t0)
        XCTAssertEqual(h.consume(a, document: field, now: t0), .insert("partial"))
        XCTAssertEqual(h.keyboardStatus(for: a, now: t0), "Recording stopped early")
    }

    // MARK: Issue #14: the stop notification carries no sender, so the stop request lives in the App Group.

    func testStopRequestIsOnlyAcceptedForTheRecordingSession() {
        var h = Handoff()
        h.request(a, document: field, now: t0)
        XCTAssertFalse(h.requestStop(a, now: t0)) // not recording yet: the keyboard starts over instead
        XCTAssertTrue(h.startRecording(a, now: t0) {})
        XCTAssertFalse(h.stopRequested)
        XCTAssertFalse(h.requestStop(b, now: t0))
        XCTAssertFalse(h.stopRequested)
        XCTAssertTrue(h.requestStop(a, now: t0))
        XCTAssertTrue(h.stopRequested)
        XCTAssertTrue(h.shouldKeepRecording(a, now: t0)) // the request does not reset the 5-minute cap clock
        XCTAssertFalse(h.shouldKeepRecording(a, now: t0 + Handoff.maxRecording))
        var abandoned = recording(a, at: t0) // the app died mid-recording: the keyboard must start over, not wait on it
        XCTAssertFalse(abandoned.requestStop(a, now: t0 + Handoff.maxRecording + Handoff.timeout + 1))
        XCTAssertFalse(abandoned.stopRequested)
        h.request(b, document: field, now: t0) // a new session never inherits the old stop
        XCTAssertFalse(h.stopRequested)
    }

    // MARK: Goal rule 3: the keyboard's 🤫 ring follows the keyboard's own session.

    func testKeyboardIndicatorFollowsTheSession() {
        var h = Handoff()
        XCTAssertEqual(h.indicatorMode(for: nil, now: t0), .idle)
        h.request(a, document: field, now: t0)
        XCTAssertEqual(h.indicatorMode(for: a, now: t0), .processing) // opening the app
        h.startRecording(a, now: t0) {}
        XCTAssertEqual(h.indicatorMode(for: a, now: t0), .recording)
        h.finishRecording(a, now: t0)
        XCTAssertEqual(h.indicatorMode(for: a, now: t0), .processing)
        h.deliver(a, text: "hi", now: t0)
        XCTAssertEqual(h.indicatorMode(for: a, now: t0), .processing)
        XCTAssertEqual(h.indicatorMode(for: a, now: t0 + Handoff.timeout + 1), .error) // timed out
        XCTAssertEqual(h.consume(a, document: field, now: t0), .insert("hi"))
        XCTAssertEqual(h.indicatorMode(for: a, now: t0), .idle)
        XCTAssertEqual(h.indicatorMode(for: b, now: t0), .error) // the keyboard's session is gone

        var wrongField = ready(a, text: "hi", at: t0)
        XCTAssertEqual(wrongField.consume(a, document: otherField, now: t0), .copy("hi"))
        XCTAssertEqual(wrongField.indicatorMode(for: a, now: t0), .idle) // copied, not lost
        wrongField.copyFailed(a, now: t0)
        XCTAssertEqual(wrongField.indicatorMode(for: a, now: t0), .error)

        var cancelled = recording(a, at: t0)
        cancelled.cancel(a, now: t0)
        XCTAssertEqual(cancelled.indicatorMode(for: a, now: t0), .idle)
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

    func testAudioIsExcludedFromICloudAndDeviceBackup() throws {
        // Application Support is backed up unless excluded, and the audio must never leave the device.
        try AudioArchive.save([0], id: UUID(), in: dir)
        let values = try URL(fileURLWithPath: dir.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let entryDir = dir.appendingPathComponent("entries-only", isDirectory: true)
        try AudioArchive.write(Recording(id: UUID(), date: Date(), outcome: .cancelled), in: entryDir)
        XCTAssertEqual(try URL(fileURLWithPath: entryDir.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testHistoryEntrySitsNextToItsAudioAndRoundTrips() throws {
        let entry = Recording(id: UUID(), date: Date(timeIntervalSince1970: 5), outcome: .transcribed, text: "hi")
        try AudioArchive.write(entry, in: dir)
        XCTAssertEqual(entry.audio, AudioArchive.url(for: entry.id, in: dir).lastPathComponent)
        XCTAssertEqual(AudioArchive.history(in: dir), [entry])
    }

    func testSweepDeletesOnlyRecordingsOlderThanTheAge() throws {
        let now = Date()
        let old = Recording(id: UUID(), date: now.addingTimeInterval(-25 * 3600), outcome: .transcribed)
        let new = Recording(id: UUID(), date: now.addingTimeInterval(-23 * 3600), outcome: .cancelled)
        for entry in [old, new] {
            try AudioArchive.save([0.5], id: entry.id, in: dir)
            try AudioArchive.write(entry, in: dir)
        }
        XCTAssertEqual(AudioArchive.sweep(olderThan: 24 * 3600, now: now, in: dir), [old.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioArchive.url(for: old.id, in: dir).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioArchive.url(for: new.id, in: dir).path))
        XCTAssertEqual(AudioArchive.history(in: dir), [new])
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

// MARK: Product rule 3: the 🤫 indicator is tiny and sits in the bottom-left corner.

@MainActor
final class IndicatorTests: XCTestCase {
    func testIndicatorIsInTheBottomLeftCornerWithTheStateNextToIt() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 180))
        let indicator = Indicator(in: view)
        indicator.show(.error, "Could not transcribe")
        view.layoutIfNeeded()
        let psst = try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first { $0.text == "🤫" })
        let status = indicator.status
        XCTAssertEqual(status.text, "Could not transcribe")
        XCTAssertEqual(psst.font.pointSize, 18)
        XCTAssertEqual(psst.frame.minX, 8, accuracy: 0.5)
        XCTAssertEqual(psst.frame.maxY, 172, accuracy: 0.5)
        XCTAssertFalse(psst.isUserInteractionEnabled) // never takes a tap meant for a key
        XCTAssertGreaterThanOrEqual(status.frame.minX, psst.frame.maxX)
        XCTAssertLessThanOrEqual(status.frame.maxX, 367)
    }

    /// Goal rule 3: the states show at the indicator, in the same colors as on the Mac
    /// (Sources/Shepetal/Indicator.swift: recording red, processing blue, error yellow, idle no ring).
    func testStateRingUsesTheMacColors() {
        XCTAssertNil(Indicator.Mode.idle.color)
        XCTAssertEqual(Indicator.Mode.recording.color, .systemRed)
        XCTAssertEqual(Indicator.Mode.processing.color, .systemBlue)
        XCTAssertEqual(Indicator.Mode.error.color, .systemYellow)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 180))
        let indicator = Indicator(in: view)
        indicator.show(.recording, nil)
        XCTAssertEqual(indicator.psst.layer.borderWidth, 2)
        XCTAssertEqual(indicator.psst.layer.borderColor, UIColor.systemRed.cgColor)
        indicator.show(.idle, nil)
        XCTAssertEqual(indicator.psst.layer.borderWidth, 0) // idle: just 🤫, no ring
    }

    func testLiveActivityGoesStaleOnlyAfterTheStatesTimeout() {
        // A Live Activity left by an app that died says so instead of "Listening" for hours.
        XCTAssertEqual(Indicator.Mode.recording.staleAfter, Handoff.maxRecording + Handoff.timeout)
        XCTAssertEqual(Indicator.Mode.processing.staleAfter, Handoff.timeout)
        XCTAssertNil(Indicator.Mode.idle.staleAfter)
        XCTAssertNil(Indicator.Mode.error.staleAfter) // ended by the app a few seconds later anyway
    }
}
