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
    private(set) var heard: [Float] = []  // the samples of the last call

    init(_ text: String = "", error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        calls += 1
        heard = samples
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
        let run = await pipeline.process(samples, engine: engine, context: { (before, "", "") }, sendPaste: { [unowned self] in
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
        // 0.25 s of slack for a loaded machine; a landed paste that also waited out the failure timeout would take
        // failAfter + restoreDelay.
        XCTAssertLessThan(elapsed, PasteCheck.failAfter + 0.25, "a paste that landed does not wait out the failure timeout")
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

    /// Esc while transcribing (F03): the App cancels the transcription Task. Nothing is pasted, the clipboard is
    /// untouched, and the row is kept as cancelled with its audio, and with its text when STT had finished.
    @MainActor
    func testEscWhileTranscribingInsertsNothingAndKeepsTheRow() async throws {
        for throwsOnCancel in [false, true] {
            let engine = CancellingEngine("Send the report today.", throwsOnCancel: throwsOnCancel)
            let change = pasteboard.changeCount
            let (run, row) = try await Task { @MainActor in try await self.process(speech, engine) }.value
            XCTAssertNil(run.error, "a cancel is not an error")
            XCTAssertEqual(row.outcome, .cancelled)
            XCTAssertEqual(row.text, throwsOnCancel ? "" : Cleanup.apply("Send the report today."))
            XCTAssertNil(run.paste)
            XCTAssertEqual(pastes, 0, "nothing may be pasted after Esc")
            XCTAssertEqual(pasteboard.changeCount, change, "the clipboard must not be touched")
        }
    }

    /// Re-transcribe in the hub runs the same text step as dictation, so it strips non-speech tags too.
    @MainActor
    func testFinishTextStripsTagsForReTranscribeToo() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let tagged = await pipeline.finishText("[BLANK_AUDIO] um, send it")
        XCTAssertEqual(tagged.text, Cleanup.apply("send it"))
        let music = await pipeline.finishText("[Music]")
        XCTAssertEqual(music.text, "")
        try "dentist => orthodontist\n".write(to: pipeline.dictionary, atomically: true, encoding: .utf8)
        let dictated = await pipeline.finishText("call the dentist")
        XCTAssertEqual(dictated.text, Cleanup.apply("call the orthodontist"), "re-transcribe applies the personal dictionary too")
    }

    /// Dictation and the hub's re-transcribe share one text step, so a re-transcribed row gets the cleanup
    /// model's rewrite too, not only the rules.
    @MainActor
    func testDictationAndRetranscribeBothUseTheCleanupModel() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.cleanup = RewriteModel(["Send it to John, I mean Jane.": "Send it to Jane."])
        let run = await pipeline.process(speech, engine: FakeEngine("Send it to John, I mean Jane."), context: { ("", "", "") },
                                         sendPaste: { [unowned self] e in if e.type == .keyDown { _ = pasteboard.string(forType: .string) } })
        XCTAssertEqual(run.entry.text, "Send it to Jane.")
        XCTAssertEqual(run.cleanupModel, "rewrite")
        let row = try XCTUnwrap(try pipeline.history.recent().first { $0.id == run.entry.id })
        let again = try await pipeline.retranscribe(row, with: FakeEngine("Send it to John, I mean Jane."))
        XCTAssertEqual(again.text, "Send it to Jane.")
        XCTAssertEqual(try pipeline.history.recent().first { $0.id == row.id }?.text, "Send it to Jane.")
    }

    /// F35: the model's numbered list reaches the cursor as lines, through the text step, InsertionRules.fit and
    /// the paste, and History keeps the same lines. Without the model the user gets the rules' text, as before.
    @MainActor
    func testSpokenListIsPastedAsNumberedLines() async throws {
        let said = "Things to buy. First, milk. Second, eggs. Third, bread."
        let list = "Things to buy:\n1. Milk\n2. Eggs\n3. Bread"
        for model in [RewriteModel([said: list]), nil] {
            let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
            pipeline.cleanup = model
            var pasted: String?
            let run = await pipeline.process(speech, engine: FakeEngine(said), context: { ("", "", "") },
                                             sendPaste: { [pasteboard] e in if e.type == .keyDown { pasted = pasteboard!.string(forType: .string) } })
            let want = model == nil ? Cleanup.apply(said) : list
            XCTAssertEqual(pasted, want, model == nil ? "rules only" : "the list is pasted line for line")
            XCTAssertEqual(run.inserted, want)
            XCTAssertEqual(run.cleanupModel, model?.name)
            XCTAssertEqual(try pipeline.history.recent().first { $0.id == run.entry.id }?.text, want)
        }
    }

    /// Dates run on the cleaned text: the stutter goes first, then "the first of March" becomes 01.03.
    /// The dictionary runs after them, so text the user stored there is inserted as written.
    @MainActor
    func testFinishTextWritesSpokenDatesAsNumbersBeforeTheDictionary() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        try "launch day => the first of March launch\n".write(to: pipeline.dictionary, atomically: true, encoding: .utf8)
        let stutter = await pipeline.finishText("Let's meet on the the first of um March.")
        XCTAssertEqual(stutter.text, "Let's meet on 01.03.")
        let year = await pipeline.finishText("Twenty sixth of July twenty twenty-six.")
        XCTAssertEqual(year.text, "26.07.26.")
        let stored = await pipeline.finishText("see you at launch day")
        XCTAssertEqual(stored.text, "see you at the first of March launch")
    }

    /// Dates run after the cleanup model too, so a date the user corrected still comes out as numbers
    /// (the model sees spoken words, which its word guard checks).
    @MainActor
    func testDatesRunOnTheCleanupModelsRewrite() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.cleanup = RewriteModel(["Meet on Tuesday, I mean the first of March.": "Meet on the first of March."])
        let fixed = await pipeline.finishText("Meet on Tuesday, I mean the first of March.")
        XCTAssertTrue(fixed.usedModel)
        XCTAssertEqual(fixed.text, "Meet on 01.03.")
    }

    /// M-CLEAN-1: the 🤫 menu offers this Mac's cleanup model until it is in the data dir's models folder or a
    /// model is loaded, and until then Home says the rules run alone.
    @MainActor
    func testTheCleanupModelIsOfferedUntilItIsDownloadedOrLoaded() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        guard let m = currentCleanupModel() else { return XCTAssertNil(pipeline.cleanupToDownload, "Intel: rules only, no offer") }
        XCTAssertEqual(pipeline.cleanupToDownload, m)
        if ProcessInfo.processInfo.environment["SHEPETAL_CLEANUP_MODEL"] == nil {
            let status = await pipeline.loadCleanup()
            XCTAssertEqual(status, "Rules only (download the cleanup model from the 🤫 menu)")
            XCTAssertEqual(pipeline.cleanupStatus, status, "Home's Cleanup line")
            XCTAssertNil(pipeline.cleanup)
        }
        pipeline.cleanup = RewriteModel([:])
        XCTAssertNil(pipeline.cleanupToDownload, "a model is loaded (SHEPETAL_CLEANUP_MODEL): no offer")
        pipeline.cleanup = nil
        try FileManager.default.createDirectory(at: pipeline.models, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: pipeline.models.appendingPathComponent(m.file).path, contents: Data()))
        XCTAssertNil(pipeline.cleanupToDownload, "downloaded: no offer, even before it loads")
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

    /// F37: a style picked for work messages reaches Slack's paste and its history row. Settings are read from
    /// a throwaway defaults suite, never the app's own.
    @MainActor
    func testSlackDictationWithCasualDropsTheFinalPeriod() async throws {
        let suite = "shepetal-styles-pipeline-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Style.casual.rawValue, forKey: Styles.key(.work))
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.styleDefaults = defaults
        var pasted: String?
        let slack = AppContext(name: "Slack", bundleId: "com.tinyspeck.slackmacgap")
        let run = await pipeline.process(speech, engine: FakeEngine("Hey Anna, the build is green."), app: slack,
                                         context: { ("", "", "") },
                                         sendPaste: { [pasteboard] e in if e.type == .keyDown { pasted = pasteboard!.string(forType: .string) } })
        XCTAssertEqual(run.entry.text, "Hey Anna the build is green")
        XCTAssertEqual(pasted, "Hey Anna the build is green")
        XCTAssertEqual(try pipeline.history.recent().first { $0.id == run.entry.id }?.text, "Hey Anna the build is green")
        let other = await pipeline.finishText("Hey Anna, the build is green.", bundleId: "com.apple.TextEdit")
        XCTAssertEqual(other.text, "Hey Anna, the build is green.", "TextEdit is Other, which was never picked")
    }

    /// F37: until a style is picked, every app gets the text it got before styles existed.
    @MainActor
    func testWithoutAPickTheOutputIsUnchanged() async throws {
        let suite = "shepetal-styles-pipeline-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.styleDefaults = defaults
        for id in ["com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.MobileSMS", "com.apple.TextEdit", ""] {
            let styled = await pipeline.finishText("Hey Anna, I will send it at 5 p.m.", bundleId: id)
            let want = Cleanup.apply("Hey Anna, I will send it at 5 p.m.")
            XCTAssertEqual(styled.text, id == "com.apple.mail" ? EmailFormat.apply(want) : want, id)  // F36 lays out email
        }
    }

    /// F37: re-transcribing a row uses that row's app and page, not the app in front now, and Very casual keeps
    /// the dictionary's casing because the dictionary runs after the style.
    @MainActor
    func testRetranscribeStylesByTheRowsAppAndKeepsDictionaryCasing() async throws {
        let suite = "shepetal-styles-pipeline-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Style.veryCasual.rawValue, forKey: Styles.key(.work))
        let (_, row) = try await process(speech, FakeEngine("Send it."))
        var slackWeb = row
        slackWeb.bundleId = "com.google.Chrome"
        slackWeb.url = "https://app.slack.com/client"
        try "GitHub\n".write(to: root.appendingPathComponent("dictionary.txt"), atomically: true, encoding: .utf8)
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.styleDefaults = defaults
        let e = try await pipeline.retranscribe(slackWeb, with: FakeEngine("I pushed it to github."))
        XCTAssertEqual(e.text, "i pushed it to GitHub")
        XCTAssertEqual(try pipeline.history.recent().first { $0.id == row.id }?.text, "i pushed it to GitHub")
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

    // MARK: F42 and F22 through the pipeline (mac80 W2 INSERT)

    /// Runs one dictation with "press enter" on or off. `read`: the app takes the paste at ⌘V.
    @MainActor
    func pressEnterRun(_ said: String, read: Bool = true, on: Bool = true, focusKept: Bool? = nil)
        async throws -> (run: Pipeline.Run, keys: [Int64], pasted: String?) {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.pressEnterCommand = { on }
        var keys: [Int64] = [], pasted: String?
        let run = await pipeline.process(speech, engine: FakeEngine(said), context: { ("", "", "") },
                                         focusKept: { focusKept }, sendPaste: { [pasteboard] e in
            guard e.type == .keyDown else { return }
            let code = e.getIntegerValueField(.keyboardEventKeycode)
            keys.append(code)
            if read, code != 36 { pasted = pasteboard!.string(forType: .string) }
        })
        return (run, keys, pasted)
    }

    /// F42: the phrase never reaches the field or the history text, and Return follows a landed paste once.
    @MainActor
    func testPressEnterPastesWithoutThePhraseThenPressesReturnOnce() async throws {
        let (run, keys, pasted) = try await pressEnterRun("See you soon, press enter.")
        XCTAssertEqual(run.entry.text, "See you soon.", "history keeps the text without the command")
        XCTAssertEqual(run.entry.rawText, "See you soon, press enter.", "and the raw transcript as heard")
        XCTAssertEqual(pasted, run.inserted)
        XCTAssertFalse(run.inserted.lowercased().contains("enter"))
        XCTAssertEqual(run.entry.outcome, .inserted)
        XCTAssertEqual(keys.filter { $0 == 36 }.count, 1, "exactly one Return")
        XCTAssertEqual(keys.last, 36, "after the paste")
    }

    /// F42 and rule 8: a paste that did not land, or a window that changed, gets no Return; the text without
    /// the phrase waits on the clipboard for ⌘V.
    @MainActor
    func testPressEnterNeverPressesReturnWhenThePasteFailedOrFocusMoved() async throws {
        let failed = try await pressEnterRun("See you soon press enter", read: false)
        XCTAssertEqual(failed.run.error, PasteGate.notLanded)
        XCTAssertFalse(failed.keys.contains(36))
        XCTAssertEqual(pasteboard.string(forType: .string), failed.run.inserted)
        XCTAssertFalse(failed.run.inserted.lowercased().contains("enter"))
        let moved = try await pressEnterRun("Talk to you later press enter", focusKept: false)
        XCTAssertEqual(moved.run.error, PasteGate.focusMoved)
        XCTAssertTrue(moved.keys.isEmpty, "nothing pasted, nothing pressed")
        XCTAssertNotEqual(moved.run.inserted, failed.run.inserted, "another text, so the clipboard check below can fail")
        XCTAssertEqual(pasteboard.string(forType: .string), moved.run.inserted)
    }

    /// F42: re-transcribing a row keeps the command out of its text too, as the dictation did.
    @MainActor
    func testRetranscribeLeavesPressEnterOutOfTheText() async throws {
        let (_, row) = try await process(speech, FakeEngine("See you soon."))
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.pressEnterCommand = { true }
        let e = try await pipeline.retranscribe(row, with: FakeEngine("See you soon, press enter."))
        XCTAssertEqual(e.text, "See you soon.")
        XCTAssertEqual(e.rawText, "See you soon, press enter.", "the raw transcript as heard")
    }

    /// F42 off (the default): "press enter" is text like any other, and no Return is pressed.
    @MainActor
    func testPressEnterOffPastesThePhraseAsText() async throws {
        let (run, keys, pasted) = try await pressEnterRun("See you soon press enter", on: false)
        XCTAssertTrue(run.entry.text.lowercased().hasSuffix("press enter"))
        XCTAssertEqual(pasted, run.inserted)
        XCTAssertFalse(keys.contains(36))
    }

    /// F42: only the phrase leaves nothing to paste, so no Return either (no paste confirms the window takes text).
    @MainActor
    func testPressEnterAloneSendsNothing() async throws {
        let change = pasteboard.changeCount
        let (run, keys, _) = try await pressEnterRun("Press enter.")
        XCTAssertEqual(run.error, PressEnter.nothingToSend)
        XCTAssertTrue(keys.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, change, "the clipboard is not touched")
        XCTAssertEqual(run.entry.rawText, "Press enter.")
    }

    /// F22: the dictation's app picks the paste mode. Windows App syncs the clipboard during the delay, before the
    /// chord; that read is the paste, not paste_failed.
    @MainActor
    func testRemoteViewerReadBeforeTheChordIsInserted() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let pb = pasteboard!, start = pb.changeCount
        var keyDownsBeforeRead = -1, keyDowns = 0
        let viewer = Task { @MainActor in
            while pb.changeCount == start, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            keyDownsBeforeRead = keyDowns
            _ = pb.string(forType: .string)
        }
        defer { viewer.cancel() }
        let run = await pipeline.process(speech, engine: FakeEngine("Hello over there."),
                                         app: AppContext(name: "Windows App", bundleId: "com.microsoft.rdc.macos"),
                                         context: { ("", "", "") }, sendPaste: { if $0.type == .keyDown { keyDowns += 1 } })
        XCTAssertEqual(keyDownsBeforeRead, 0, "the viewer read before the chord")
        XCTAssertEqual(run.entry.outcome, .inserted)
        XCTAssertNil(run.error)
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier")
    }

    /// F22 and rule 8: focus that moves during the remote delay gets no chord; the text waits for ⌘V.
    @MainActor
    func testRemoteViewerFocusMovedDuringTheDelayPostsNothing() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        var asked = 0, keyDowns = 0
        let run = await pipeline.process(speech, engine: FakeEngine("Hello over there."),
                                         app: AppContext(name: "Screen Sharing", bundleId: "com.apple.ScreenSharing"),
                                         context: { ("", "", "") }, focusKept: { asked += 1; return asked <= 2 },
                                         sendPaste: { if $0.type == .keyDown { keyDowns += 1 } })
        XCTAssertEqual(asked, 3, "the pipeline's two checks, then the one after the delay")
        XCTAssertEqual(keyDowns, 0)
        XCTAssertEqual(run.entry.outcome, .pasteFailed)
        XCTAssertEqual(pasteboard.string(forType: .string), run.inserted)
    }
}

/// Cancels the Task it runs in, the way Esc does while the model is busy, then returns `text` or throws.
final class CancellingEngine: SpeechEngine {
    let name = "fake"
    let text: String
    let throwsOnCancel: Bool

    init(_ text: String, throwsOnCancel: Bool) {
        self.text = text
        self.throwsOnCancel = throwsOnCancel
    }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        withUnsafeCurrentTask { $0?.cancel() }
        if throwsOnCancel { throw CancellationError() }
        return text
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

/// A cleanup model with canned rewrites.
private final class RewriteModel: CleanupModel, @unchecked Sendable {
    let name = "rewrite"
    let answers: [String: String]
    init(_ answers: [String: String]) { self.answers = answers }
    func rewrite(_ text: String) throws -> String { answers[text] ?? text }
}
