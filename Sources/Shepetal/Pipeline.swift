import AppKit
import ShepetalCore

enum Paths {
    /// Owner-only data dir. SHEPETAL_HOME moves it (the end-to-end test uses that).
    static let root: URL = ProcessInfo.processInfo.environment["SHEPETAL_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Shepetal")
    static var audio: URL { root.appendingPathComponent("audio") }
    static var history: URL { root.appendingPathComponent("history.sqlite") }
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
    let inserter = Inserter()

    init() throws {
        try AudioStore.makeOwnerOnlyDirectory(Paths.root)
        store = try AudioStore(dir: Paths.audio)
        history = try History(path: Paths.history)
    }

    func process(_ samples: [Float], engine: SpeechEngine?, context: () -> (before: String, after: String),
                 sendPaste: (CGEvent) -> Void) async -> Run {
        let t0 = ProcessInfo.processInfo.systemUptime
        var run = Run(entry: HistoryEntry(id: UUID().uuidString, createdAt: Date(), outcome: .failed, audioPath: "",
                                          durationMs: Self.ms(samples)))
        save(samples, &run)  // first, so the audio survives anything below
        let saveError = run.error
        let error = await transcribeAndInsert(samples, engine, t0, context, sendPaste, &run)
        run.error = saveError ?? error
        record(&run)
        return run
    }

    /// Returns an error message, or nil when the text landed.
    private func transcribeAndInsert(_ samples: [Float], _ engine: SpeechEngine?, _ t0: TimeInterval,
                                     _ context: () -> (before: String, after: String),
                                     _ sendPaste: (CGEvent) -> Void, _ run: inout Run) async -> String? {
        guard let engine else { return "Speech model is not loaded" }
        run.entry.model = engine.name
        do {
            run.entry.rawText = try await engine.transcribe(samples, wav: URL(fileURLWithPath: run.entry.audioPath))
        } catch {
            if Task.isCancelled { run.entry.outcome = .cancelled; return nil }  // Esc while transcribing
            return "Transcription failed: \(error.localizedDescription)"
        }
        run.entry.text = Cleanup.apply(run.entry.rawText)
        run.readyMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        guard !run.entry.text.isEmpty else { return "No speech heard" }
        if Task.isCancelled { run.entry.outcome = .cancelled; return nil }  // Esc while transcribing: keep the text, insert nothing
        let (before, after) = context()
        run.inserted = InsertionRules.fit(run.entry.text, before: before, after: after)
        let paste = await inserter.insert(run.inserted, sendPaste: sendPaste)
        run.paste = paste
        run.entry.outcome = paste.landed ? .inserted : .pasteFailed
        return paste.landed ? nil : "Paste did not land. The text is in Recent."
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
