import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// Speech engine double: returns `text` or throws, and counts calls.
final class FakeEngine: SpeechEngine {
    let name = "fake"
    var text: String
    var error: Error?
    private(set) var calls = 0

    init(_ text: String = "", error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        calls += 1
        if let error { throw error }
        return text
    }
}

/// What happens after release. Every recording keeps its audio and a history row (goal rule 4), and nothing
/// is pasted unless there is text (F51). A paste nobody reads is reported and its text
/// is left on the clipboard (goal rule 8); a paste that lands gets the old clipboard back (F20).
/// Runs on a temp data dir and a private pasteboard, never on the user's clipboard or data.
final class PipelineTests: XCTestCase {
    var root: URL!
    var pasteboard: NSPasteboard!
    var pastes = 0

    /// 1 s at -30 dBFS RMS: well above the speech floor.
    let speech = tone(db: -30)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-test-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func process(_ samples: [Float], _ engine: SpeechEngine?, before: String = "",
                 sendPaste: @escaping (CGEvent) -> Void = { _ in }) async throws -> (Pipeline.Run, HistoryEntry) {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let run = await pipeline.process(samples, engine: engine, context: { (before, "") }, sendPaste: { [unowned self] in
            self.pastes += 1
            sendPaste($0)
        })
        let row = try XCTUnwrap(try pipeline.history.recent().first { $0.id == run.entry.id }, "no history row")
        let mode = try FileManager.default.attributesOfItem(atPath: row.audioPath)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: row.audioPath)), AudioStore.wav(samples),
                       "the WAV holds the exact samples")
        return (run, row)
    }

    /// No paste was posted and the clipboard was never written.
    @MainActor
    func assertNoSpeech(_ samples: [Float], _ engine: SpeechEngine, file: StaticString = #filePath, line: UInt = #line) async throws {
        let change = pasteboard.changeCount
        let (run, row) = try await process(samples, engine)
        XCTAssertEqual(run.error, "No speech heard", file: file, line: line)
        XCTAssertEqual(row.outcome, .noSpeech, file: file, line: line)
        XCTAssertEqual(row.text, "", file: file, line: line)
        XCTAssertNil(run.paste, file: file, line: line)
        XCTAssertEqual(pastes, 0, "nothing may be pasted", file: file, line: line)
        XCTAssertEqual(pasteboard.changeCount, change, "the clipboard must not be touched", file: file, line: line)
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier", file: file, line: line)
    }

    @MainActor
    func testEmptyTranscriptPastesNothingAndKeepsAudio() async throws {
        try await assertNoSpeech(speech, FakeEngine(""))
    }

    @MainActor
    func testFillerOnlyTranscriptIsNoSpeech() async throws {
        try await assertNoSpeech(speech, FakeEngine("um, uh"))
    }

    @MainActor
    func testWhisperBlankTagIsNoSpeech() async throws {
        let engine = FakeEngine("[BLANK_AUDIO]")
        try await assertNoSpeech(speech, engine)
        XCTAssertEqual(try Pipeline(root: root, pasteboard: pasteboard).history.recent().first?.rawText, "[BLANK_AUDIO]",
                       "history keeps what the model printed")
    }

    @MainActor
    func testSilentRecordingNeverReachesTheModel() async throws {
        let engine = FakeEngine("thank you")  // what Whisper likes to hear in silence
        try await assertNoSpeech([Float](repeating: 0, count: 16_000), engine)
        try await assertNoSpeech(noise(db: -70), engine)
        XCTAssertEqual(engine.calls, 0)
        let loud = FakeEngine("")
        _ = try await process(speech, loud)
        XCTAssertEqual(loud.calls, 1, "speech above the floor goes to the model")
    }

    @MainActor
    func testPasteNobodyReadsIsPasteFailed() async throws {
        let t0 = Date()
        let (run, row) = try await process(speech, FakeEngine("Send the report today."))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), PasteCheck.failAfter)
        XCTAssertEqual(pastes, 2, "Cmd down and up were posted")
        XCTAssertEqual(run.paste?.landed, false)
        XCTAssertEqual(row.outcome, .pasteFailed)
        XCTAssertEqual(row.text, "Send the report today.", "the text is kept for Recent")
        XCTAssertEqual(run.error, "Paste did not land. The text is on the clipboard: press ⌘V to paste it.")
        // Goal rule 8: the text stays on the clipboard as plain text and the old clipboard is not restored.
        XCTAssertEqual(pasteboard.string(forType: .string), "Send the report today.", "the text is left on the clipboard")
        let markers: Set<NSPasteboard.PasteboardType> = [.init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")]
        // #42: the Concealed and Transient markers stay on it (clipboard managers skip it; ⌘V still pastes it).
        XCTAssertTrue(markers.isSubset(of: Set(pasteboard.types ?? [])), "the text left on the clipboard keeps its markers")
        XCTAssertEqual(run.paste?.restored, false)
    }

    @MainActor
    func testPasteThatIsReadLands() async throws {
        var pasted: String?
        let t0 = Date()
        let (run, row) = try await process(speech, FakeEngine("Send the report today."), before: "Please") { [pasteboard] event in
            if event.type == .keyDown { pasted = pasteboard!.string(forType: .string) }  // the app under the cursor reads it
        }
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(pasted, InsertionRules.fit("Send the report today.", before: "Please", after: ""))
        XCTAssertEqual(pasted, run.inserted)
        XCTAssertEqual(row.outcome, .inserted)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.paste?.landed, true)
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier")
        XCTAssertEqual(run.paste?.restored, true)
        XCTAssertGreaterThanOrEqual(elapsed, PasteCheck.restoreDelay, "the clipboard comes back about 0.5 s after the read")
        XCTAssertLessThan(elapsed, PasteCheck.failAfter, "a paste that landed does not wait out the failure timeout")
    }

    /// The dictionary is read from the pipeline's own data dir and runs after tag stripping and Cleanup,
    /// before the text is fitted to the cursor.
    @MainActor
    func testDictionaryRunsAfterCleanupFromTheDataDir() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "dentist => orthodontist\n".write(to: root.appendingPathComponent("dictionary.txt"), atomically: true, encoding: .utf8)
        var pasted: String?
        let (run, row) = try await process(speech, FakeEngine("[BLANK_AUDIO] um, call the dentist"), before: "Then") { [pasteboard] event in
            if event.type == .keyDown { pasted = pasteboard!.string(forType: .string) }
        }
        XCTAssertEqual(row.text, Cleanup.apply("call the orthodontist"))
        XCTAssertEqual(pasted, InsertionRules.fit(Cleanup.apply("call the orthodontist"), before: "Then", after: ""))
        XCTAssertEqual(run.inserted, pasted)
    }

    /// Re-transcribe in the hub runs the same text step as dictation, so it strips non-speech tags too.
    @MainActor
    func testFinishTextStripsTagsForReTranscribeToo() {
        XCTAssertEqual(Pipeline.finishText("[BLANK_AUDIO] um, send it", dictionary: root.appendingPathComponent("dictionary.txt")), Cleanup.apply("send it"))
        XCTAssertEqual(Pipeline.finishText("[Music]", dictionary: root.appendingPathComponent("dictionary.txt")), "")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? "dentist => orthodontist\n".write(to: root.appendingPathComponent("dictionary.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Pipeline.finishText("call the dentist", dictionary: root.appendingPathComponent("dictionary.txt")),
                       Cleanup.apply("call the orthodontist"), "re-transcribe applies the personal dictionary too")
    }

    /// Dates run on the cleaned text: the stutter goes first, then "the first of March" becomes 01.03.
    /// The dictionary runs after them, so text the user stored there is inserted as written.
    @MainActor
    func testFinishTextWritesSpokenDatesAsNumbersBeforeTheDictionary() throws {
        let dictionary = root.appendingPathComponent("dictionary.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "launch day => the first of March launch\n".write(to: dictionary, atomically: true, encoding: .utf8)
        XCTAssertEqual(Pipeline.finishText("Let's meet on the the first of um March.", dictionary: dictionary), "Let's meet on 01.03.")
        XCTAssertEqual(Pipeline.finishText("Twenty sixth of July twenty twenty-six.", dictionary: dictionary), "26.07.26.")
        XCTAssertEqual(Pipeline.finishText("see you at launch day", dictionary: dictionary), "see you at the first of March launch")
    }

    /// The hub's re-transcribe writes the same text step's result to the same row.
    @MainActor
    func testRetranscribeStripsTagsAndUpdatesTheRow() async throws {
        let (_, row) = try await process(speech, FakeEngine("Send it."))
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let e = try await pipeline.retranscribe(row, with: FakeEngine("[BLANK_AUDIO] um, send it"))
        XCTAssertEqual(e.text, Cleanup.apply("send it"))
        XCTAssertEqual(try pipeline.history.recent().first { $0.id == row.id }?.text, Cleanup.apply("send it"))
    }

    /// The hub's re-transcribe reads the pipeline's own dictionary.txt, so it gets the replacements dictation
    /// gets, and a test or a second data dir never reads the real one.
    @MainActor
    func testRetranscribeUsesThePipelinesDictionary() async throws {
        let (_, row) = try await process(speech, FakeEngine("Send it."))
        try "dentist => orthodontist\n".write(to: root.appendingPathComponent("dictionary.txt"), atomically: true, encoding: .utf8)
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let e = try await pipeline.retranscribe(row, with: FakeEngine("call the dentist"))
        XCTAssertEqual(e.text, Cleanup.apply("call the orthodontist"))
    }

    @MainActor
    func testNoEngineAndEngineErrorKeepAudio() async throws {
        let (none, noneRow) = try await process(speech, nil)
        XCTAssertEqual(none.error, "Speech model is not loaded")
        XCTAssertEqual(noneRow.outcome, .failed)

        let broken = FakeEngine(error: SpeechError("decoder crashed"))
        let (failed, failedRow) = try await process(speech, broken)
        XCTAssertEqual(failed.error, "Transcription failed: decoder crashed")
        XCTAssertEqual(failedRow.outcome, .failed)
        XCTAssertEqual(failedRow.model, "fake")
        XCTAssertEqual(pastes, 0)
    }
}

/// 1 s sine at an RMS of `db` dBFS.
func tone(db: Float, seconds: Float = 1) -> [Float] {
    let amp = Float(2).squareRoot() * pow(10, db / 20)
    return (0..<Int(seconds * 16_000)).map { amp * sin(2 * .pi * 440 * Float($0) / 16_000) }
}

/// Deterministic white noise scaled to an RMS of exactly `db` dBFS.
func noise(db: Float, count: Int = 16_000) -> [Float] {
    var x: UInt32 = 1
    let raw = (0..<count).map { _ -> Float in
        x = x &* 1_664_525 &+ 1_013_904_223
        return Float(x) / Float(UInt32.max) - 0.5
    }
    let rms = (raw.reduce(0) { $0 + $1 * $1 } / Float(count)).squareRoot()
    return raw.map { $0 * pow(10, db / 20) / rms }
}
