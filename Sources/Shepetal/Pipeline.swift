import AppKit
import ShepetalCore

enum Paths {
    /// Owner-only data dir. SHEPETAL_HOME moves it (the end-to-end test uses that).
    static let root: URL = ProcessInfo.processInfo.environment["SHEPETAL_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Shepetal")
    static var audio: URL { root.appendingPathComponent("audio") }
    static var models: URL { root.appendingPathComponent("models") }
}

/// After the mic closes: keep the audio, transcribe, clean up, fit to the cursor, insert, record history.
@MainActor
final class Pipeline {
    struct Run {
        var entry: HistoryEntry
        var readyMs: Double = 0      // release to text ready (STT + cleanup)
        var inserted: String = ""
        var paste: Inserter.Result?
        var error: String?
    }

    let store: AudioStore
    let history: History
    let inserter: Inserter
    let dictionary: URL  // dictionary.txt in this pipeline's data dir

    /// No pasteboard default: a forgotten argument must not fall back to the user's clipboard.
    /// Tests pass a temp `root` and a private named pasteboard.
    init(root: URL = Paths.root, pasteboard: NSPasteboard) throws {
        inserter = Inserter(pasteboard: pasteboard)
        try AudioStore.makeOwnerOnlyDirectory(root)
        store = try AudioStore(dir: root.appendingPathComponent("audio"))
        history = try History(path: root.appendingPathComponent("history.sqlite"))
        dictionary = root.appendingPathComponent("dictionary.txt")
    }

    /// `app` is the frontmost app at dictation start (history only). `selection` is the text the paste replaces.
    /// `focusKept` says whether the window focused when the dictation started is still focused (nil: unknown),
    /// and `secureInput` names the app holding secure input. When focus moved or secure input is on, nothing is
    /// pasted and the text is left on the clipboard (rule 8). Focus is never moved back. The defaults skip them.
    func process(_ samples: [Float], engine: SpeechEngine?, app: AppContext = AppContext(),
                 context: () -> (before: String, after: String),
                 selection: () -> String = { "" }, focusKept: () -> Bool? = { nil }, secureInput: () -> String? = { nil },
                 sendPaste: (CGEvent) -> Void) async -> Run {
        let t0 = ProcessInfo.processInfo.systemUptime
        var run = Run(entry: HistoryEntry(id: UUID().uuidString, createdAt: Date(), outcome: .failed, audioPath: "",
                                          durationMs: Self.ms(samples), app: app.name, bundleId: app.bundleId, url: app.url))
        save(samples, &run)  // first, so the audio survives anything below
        let saveError = run.error
        let error = await transcribeAndInsert(samples, engine, t0, context, selection, focusKept, secureInput, sendPaste, &run)
        run.error = saveError ?? error
        record(&run)
        return run
    }

    /// Returns an error message, or nil when the text landed.
    private func transcribeAndInsert(_ samples: [Float], _ engine: SpeechEngine?, _ t0: TimeInterval,
                                     _ context: () -> (before: String, after: String), _ selection: () -> String,
                                     _ focusKept: () -> Bool?, _ secureInput: () -> String?,
                                     _ sendPaste: (CGEvent) -> Void, _ run: inout Run) async -> String? {
        guard let engine else { return "Speech model is not loaded" }
        guard SpeechGuard.isSpeech(samples) else {  // silence never reaches the model
            let message = noSpeech(&run)
            return samples.isEmpty ? MicAudio.noAudio : message  // the mic never delivered a buffer
        }
        run.entry.model = engine.name
        do {
            run.entry.rawText = try await engine.transcribe(samples, wav: URL(fileURLWithPath: run.entry.audioPath))
        } catch {
            if Task.isCancelled { run.entry.outcome = .cancelled; return nil }  // Esc while transcribing
            return "Transcription failed: \(error.localizedDescription)"
        }
        run.entry.text = Self.finishText(run.entry.rawText, dictionary: dictionary)
        run.readyMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        if Task.isCancelled { run.entry.outcome = .cancelled; return nil }  // Esc while transcribing: keep the text, insert nothing
        guard !run.entry.text.isEmpty else { return noSpeech(&run) }
        let (before, after) = context()
        run.inserted = InsertionRules.fit(run.entry.text, before: before, after: after, selected: selection())
        if let message = PasteGate.blocked(focusKept: focusKept(), secureInputApp: secureInput()) {
            inserter.leaveOnClipboard(run.inserted)
            run.entry.outcome = .pasteFailed
            return message
        }
        let paste = await inserter.insert(run.inserted, sendPaste: sendPaste)
        run.paste = paste
        run.entry.outcome = paste.landed ? .inserted : .pasteFailed
        return paste.landed ? nil : PasteGate.notLanded
    }

    /// Silence, non-speech tags or fillers only: nothing is pasted and the clipboard is not touched.
    private func noSpeech(_ run: inout Run) -> String {
        run.entry.outcome = .noSpeech
        return "No speech heard"
    }

    /// Everything between speech-to-text and insertion, shared by dictation and re-transcription (Hub).
    /// Cleanup, then the personal dictionary (F39); InsertionRules fits the result to the cursor afterwards.
    static func finishText(_ raw: String, dictionary: URL) -> String {
        Vocabulary.load(dictionary).apply(Cleanup.apply(SpeechGuard.stripTags(raw)))
    }

    private func save(_ samples: [Float], _ run: inout Run) {
        do { run.entry.audioPath = try store.save(samples, id: run.entry.id).path } catch {
            run.error = "Could not save audio: \(error.localizedDescription)"
        }
    }

    private func record(_ run: inout Run) {
        do { try history.add(run.entry) } catch { run.error = "Could not write history: \(error.localizedDescription)" }
    }

    private static func ms(_ samples: [Float]) -> Int { samples.count * 1000 / AudioStore.sampleRate }
}
