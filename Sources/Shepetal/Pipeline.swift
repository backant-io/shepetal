import AppKit
import ShepetalCleanup
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
        var cleanupModel: String?    // set when the local model's rewrite was used
        var error: String?
    }

    let store: AudioStore
    let history: History
    let inserter: Inserter
    /// The local cleanup model (docs/models.md, Cleanup). nil: the rules run alone.
    var cleanup: CleanupModel?

    /// No default: a forgotten argument must not fall back to the user's clipboard.
    init(pasteboard: NSPasteboard) throws {
        inserter = Inserter(pasteboard: pasteboard)
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
            return "Transcription failed: \(error.localizedDescription)"
        }
        let (raw, model) = (run.entry.rawText, cleanup)
        let cleaned = await Task.detached { SmartCleanup.apply(raw, model: model) }.value
        run.entry.text = cleaned.text
        run.cleanupModel = cleaned.usedModel ? model?.name : nil
        run.readyMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        guard !run.entry.text.isEmpty else { return "No speech heard" }
        let (before, after) = context()
        run.inserted = InsertionRules.fit(run.entry.text, before: before, after: after)
        let paste = await inserter.insert(run.inserted, sendPaste: sendPaste)
        run.paste = paste
        run.entry.outcome = paste.landed ? .inserted : .pasteFailed
        return paste.landed ? nil : "Paste did not land. The text is on the clipboard: press ⌘V to paste it."
    }

    // MARK: cleanup model

    /// SHEPETAL_CLEANUP_MODEL, else this Mac's default in <data>/models.
    static var cleanupPath: String? {
        ProcessInfo.processInfo.environment["SHEPETAL_CLEANUP_MODEL"]
            ?? currentCleanupModel().map { Paths.models.appendingPathComponent($0.file).path }
    }

    /// Loads the cleanup model when its file is there. Returns the status line for the menu.
    func loadCleanup() async -> String {
        guard let path = Self.cleanupPath else { return "Cleanup: rules only on this Mac" }
        guard FileManager.default.fileExists(atPath: path) else { return "Cleanup: rules only (model not downloaded)" }
        do {
            let model = try await Task.detached { try LlamaCleanup(path: path) }.value
            cleanup = model
            return "Cleanup: \(model.name)"
        } catch {
            return "Cleanup: rules only (\(error.localizedDescription))"
        }
    }

    /// User action only: this Mac's cleanup model from Hugging Face into <data>/models, checked against its SHA-256.
    static func downloadCleanup() async throws {
        guard let m = currentCleanupModel() else { return }
        let (tmp, response) = try await URLSession.shared.download(from: m.url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpeechError("Download failed: \(response)") }
        try m.install(tmp, into: Paths.models)
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
