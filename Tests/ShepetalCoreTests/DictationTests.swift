import XCTest
@testable import ShepetalCore

/// The app path from fn events to kept audio. Every recording that ends leaves an owner-only WAV with
/// the exact mic samples and a history row that points at it, too-short and cancelled ones included (goal rule 4).
final class DictationTests: XCTestCase {
    let mic: [Float] = [0.25, -0.5, 0.125, 0]
    var root: URL!
    var history: History!
    var dictation: Dictation!
    var micOpens = true
    var transcribed: [[Float]] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-test-\(UUID().uuidString)")
        try AudioStore.makeOwnerOnlyDirectory(root)
        history = try History(path: root.appendingPathComponent("history.sqlite"))
        dictation = Dictation(store: try AudioStore(dir: root.appendingPathComponent("audio")), history: history,
                              startMic: { [unowned self] in if !self.micOpens { throw CocoaError(.featureUnsupported) } },
                              stopMic: { [mic] in mic },
                              transcribe: { [unowned self] in self.transcribed.append($0) })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The only history row, after checking that its file is 0600 and holds the mic samples.
    func keptRow() throws -> HistoryEntry {
        let rows = try history.recent()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        let mode = try FileManager.default.attributesOfItem(atPath: row.audioPath)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: row.audioPath)), AudioStore.wav(mic))
        return row
    }

    func testTooShortPressKeepsItsAudio() throws {
        try dictation.run { $0.fnDown(at: 0) }
        try dictation.run { $0.fnUp(at: 0.2) }
        XCTAssertEqual(try dictation.run { $0.tick(at: 0.7) }, [.tooShort])
        XCTAssertEqual(try keptRow().outcome, .tooShort)
        XCTAssertEqual(transcribed, [], "a too-short press is never transcribed")
    }

    func testShortcutWithFnKeepsItsAudioAsCancelled() throws {
        try dictation.run { $0.fnDown(at: 0) }
        XCTAssertEqual(try dictation.run { $0.otherKeyDown(at: 0.1) }, [.cancel])
        try dictation.run { $0.fnUp(at: 0.8) }
        XCTAssertEqual(try keptRow().outcome, .cancelled)
        XCTAssertEqual(transcribed, [], "fn+Down must not paste anything")
    }

    // Esc (F03): the recording is thrown away, but its audio is kept and marked cancelled (goal rule 4).
    func testEscKeepsAudioAsCancelled() throws {
        try dictation.run { $0.fnDown(at: 0) }
        XCTAssertEqual(try dictation.run { $0.handle(.dismiss, at: 2) }, [.cancel])
        try dictation.run { $0.fnUp(at: 3) }
        XCTAssertEqual(try keptRow().outcome, .cancelled)
        XCTAssertEqual(transcribed, [], "Esc must not transcribe or paste")
    }

    // F10: the warning keeps recording; the cap hands the recording to the transcriber like a release.
    func testForcedStopTranscribesTheSamples() throws {
        try dictation.run { $0.fnDown(at: 0) }
        XCTAssertEqual(try dictation.run { $0.tick(at: 19 * 60) }, [.warnDuration])
        XCTAssertEqual(transcribed, [], "the warning does not stop the recording")
        XCTAssertEqual(try dictation.run { $0.tick(at: 20 * 60) }, [.stop])
        XCTAssertEqual(transcribed, [mic])
        try dictation.run { $0.fnUp(at: 20 * 60 + 2) }
        XCTAssertEqual(transcribed, [mic], "the late release does not transcribe again")
        XCTAssertEqual(try history.recent(), [], "nothing is kept as cancelled or too short")
    }

    // A hold goes to the transcriber, which saves the audio first (Pipeline.process, checked by scripts/e2e-mac.sh).
    func testHoldHandsTheSamplesToTheTranscriber() throws {
        try dictation.run { $0.fnDown(at: 0) }
        try dictation.run { $0.fnUp(at: 1) }
        XCTAssertEqual(transcribed, [mic])
        XCTAssertEqual(try history.recent(), [])
    }

    // A mic that does not open must not leave the gesture holding, or the release would count as a recording.
    func testMicFailureResetsTheGesture() throws {
        micOpens = false
        XCTAssertThrowsError(try dictation.run { $0.fnDown(at: 0) })
        XCTAssertEqual(dictation.gesture.state, .idle)
        XCTAssertEqual(try dictation.run { $0.fnUp(at: 1) }, [])
        XCTAssertEqual(transcribed, [])
    }
}
