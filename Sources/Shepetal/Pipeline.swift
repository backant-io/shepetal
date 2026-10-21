import AppKit
import ShepetalCleanup
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
        var cleanupModel: String?    // set when the local model's rewrite was used
        var error: String?
    }

    let store: AudioStore
    let history: History
    let inserter: Inserter
    /// The local cleanup model (docs/models.md, Cleanup). nil: the rules run alone.
    var cleanup: CleanupModel?
    /// Home's Cleanup line. It names no model, file or path.
    private(set) var cleanupStatus = "Loading…"
    private(set) var downloadingCleanup = false
    private(set) var cleanupDownloadFailed = false
    let models: URL  // the downloaded cleanup model's dir
    let dictionary: URL  // dictionary.txt in this pipeline's data dir
    /// Writes a recording's WAV. Runs off the main thread: on Pavel's nearly full disk, while macOS purged
    /// space, one such write took 86 s, and fn, the menu and rule 8 froze with it (M-NS-1). Tests stall it.
    var writeAudio: @Sendable (_ samples: [Float], _ id: String) throws -> URL

    /// No pasteboard default: a forgotten argument must not fall back to the user's clipboard.
    /// Tests pass a temp `root` and a private named pasteboard.
    init(root: URL = Paths.root, pasteboard: NSPasteboard) throws {
        inserter = Inserter(pasteboard: pasteboard)
        try AudioStore.makeOwnerOnlyDirectory(root)
        let store = try AudioStore(dir: root.appendingPathComponent("audio"))
        self.store = store
        writeAudio = { try store.save($0, id: $1) }
        history = try History(path: root.appendingPathComponent("history.sqlite"))
        dictionary = root.appendingPathComponent("dictionary.txt")
        models = root.appendingPathComponent("models")
    }

    /// `app` is the frontmost app at dictation start (history only). `context` is the text around the cursor and
    /// the selection the paste replaces.
    /// `focusKept` says whether the window focused when the dictation started is still focused (nil: unknown),
    /// and `secureInput` names the app holding secure input. When focus moved or secure input is on, nothing is
    /// pasted and the text is left on the clipboard (rule 8). Focus is never moved back. The defaults skip them.
    /// `decided` gets the outcome (an error message, or nil when the text landed) as soon as it is known; the
    /// WAV and the history row can still be waiting on the disk then. `process` returns once both are written.
    func process(_ samples: [Float], engine: SpeechEngine?, app: AppContext = AppContext(),
                 context: () -> FocusedText.Context,
                 focusKept: () -> Bool? = { nil }, secureInput: () -> String? = { nil },
                 sendPaste: (CGEvent) -> Void, decided: (String?) -> Void = { _ in }) async -> Run {
        let t0 = ProcessInfo.processInfo.systemUptime
        var run = Run(entry: HistoryEntry(id: UUID().uuidString, createdAt: Date(), outcome: .failed, audioPath: "",
                                          durationMs: Self.ms(samples), app: app.name, bundleId: app.bundleId, url: app.url))
        let id = run.entry.id, write = writeAudio
        let saving = Task.detached { try write(samples, id) }  // first, so the audio survives anything below
        let error = await transcribeAndInsert(samples, engine, t0, saving, context, focusKept, secureInput, sendPaste, &run)
        decided(error)
        let saveError = await saved(saving, &run)
        run.error = saveError ?? error
        record(&run)
        return run
    }

    /// Paste last and copy last: the newest history text, a paste that did not land included.
    var lastText: String? { ShepetalCore.lastText(in: (try? history.recent(limit: 50)) ?? []) }

    /// Copy last (⌃⌘C): the last text on the clipboard. nil, and the clipboard left alone, when there is none.
    func copyLast() -> String? {
        guard let text = lastText else { return nil }
        copy(text)
        return text
    }

    /// Copy last and the 🤫 menu's Recent: plain text on the clipboard, the user's to keep.
    func copy(_ text: String) {
        inserter.pasteboard.clearContents()
        inserter.pasteboard.setString(text, forType: .string)
    }

    /// Returns an error message, or nil when the text landed.
    private func transcribeAndInsert(_ samples: [Float], _ engine: SpeechEngine?, _ t0: TimeInterval,
                                     _ saving: Task<URL, Error>,
                                     _ context: () -> FocusedText.Context,
                                     _ focusKept: () -> Bool?, _ secureInput: () -> String?,
                                     _ sendPaste: (CGEvent) -> Void, _ run: inout Run) async -> String? {
        guard let engine else { return "Speech model is not loaded" }
        guard SpeechGuard.isSpeech(samples) else {  // silence never reaches the model
            let message = noSpeech(&run)
            return samples.isEmpty ? MicAudio.noAudio : message  // the mic never delivered a buffer
        }
        run.entry.model = engine.name
        do {
            let heard = await Task.detached { VoiceIsolation.apply(samples) }.value  // the kept WAV stays raw
            // Only an engine that reads the file waits for the disk; the others start on the samples at once.
            let wav = engine.readsWav ? try await saving.value : store.url(run.entry.id)
            run.entry.rawText = try await engine.transcribe(heard, wav: wav)
        } catch {
            if Task.isCancelled { run.entry.outcome = .cancelled; return nil }  // Esc while transcribing
            return "Transcription failed: \(error.localizedDescription)"
        }
        let cleaned = await finishText(run.entry.rawText)
        run.entry.text = cleaned.text
        run.cleanupModel = cleaned.usedModel ? cleanup?.name : nil
        run.readyMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        if Task.isCancelled { run.entry.outcome = .cancelled; return nil }  // Esc while transcribing: keep the text, insert nothing
        guard !run.entry.text.isEmpty else { return noSpeech(&run) }
        // Rule 8 before the field is read: when the text is not pasted, the field that has focus now is not
        // where it goes. And again right before the paste: focus or secure input can change during the read.
        if let message = blocked(focusKept, secureInput, &run) { return message }
        let (before, after, selected) = context()
        run.inserted = InsertionRules.fit(run.entry.text, before: before, after: after, selected: selected)
        if let message = blocked(focusKept, secureInput, &run) { return message }
        let paste = await inserter.insert(run.inserted, sendPaste: sendPaste)
        run.paste = paste
        run.entry.outcome = paste.landed ? .inserted : .pasteFailed
        return paste.landed ? nil : PasteGate.notLanded
    }

    /// Rule 8: nothing is pasted when focus moved or secure input is on. The text waits on the clipboard as
    /// dictated, since the user pastes it somewhere else.
    private func blocked(_ focusKept: () -> Bool?, _ secureInput: () -> String?, _ run: inout Run) -> String? {
        guard let message = PasteGate.blocked(focusKept: focusKept(), secureInputApp: secureInput()) else { return nil }
        run.inserted = InsertionRules.fit(run.entry.text, before: "", after: "")
        inserter.leaveOnClipboard(run.inserted)
        run.entry.outcome = .pasteFailed
        return message
    }

    /// Silence, non-speech tags or fillers only: nothing is pasted and the clipboard is not touched.
    private func noSpeech(_ run: inout Run) -> String {
        run.entry.outcome = .noSpeech
        return "No speech heard"
    }

    /// Everything between speech-to-text and insertion, shared by dictation and re-transcription (Hub): tags
    /// stripped, the rules, the local cleanup model when it is loaded, spoken dates as numbers
    /// (docs/text-rules.md), then the personal dictionary (F39), whose text is inserted as written.
    /// InsertionRules fits the result to the cursor afterwards. Runs off the main thread.
    func finishText(_ raw: String) async -> (text: String, usedModel: Bool) {
        let model = cleanup, dictionary = dictionary
        return await Task.detached {
            let cleaned = SmartCleanup.apply(SpeechGuard.stripTags(raw), model: model)
            return (Vocabulary.load(dictionary).apply(Dates.apply(cleaned.text)), cleaned.usedModel)
        }.value
    }

    // MARK: cleanup model

    /// SHEPETAL_CLEANUP_MODEL, else this Mac's default in <data>/models.
    var cleanupPath: String? {
        ProcessInfo.processInfo.environment["SHEPETAL_CLEANUP_MODEL"]
            ?? currentCleanupModel().map { models.appendingPathComponent($0.file).path }
    }

    /// This Mac's cleanup model while it is neither loaded nor downloaded: the 🤫 menu offers it. nil on Intel.
    var cleanupToDownload: CleanupModelFile? {
        guard cleanup == nil, let m = currentCleanupModel(),
              !FileManager.default.fileExists(atPath: models.appendingPathComponent(m.file).path) else { return nil }
        return m
    }

    /// Loads the cleanup model when its file is there. Returns Home's Cleanup line (E2E prints it too).
    @discardableResult
    func loadCleanup() async -> String {
        cleanupStatus = await load()
        return cleanupStatus
    }

    private func load() async -> String {
        guard let path = cleanupPath else { return "Rules only on this Mac" }
        guard FileManager.default.fileExists(atPath: path) else { return "Rules only (download the cleanup model from the 🤫 menu)" }
        do {
            cleanup = try await Task.detached { try LlamaCleanup(path: path) }.value
            return "On"
        } catch {
            // The UI names no model, file or path; the detail goes to stderr.
            FileHandle.standardError.write(Data("cleanup model: \(error)\n".utf8))
            return "Rules only (the model could not be loaded)"
        }
    }

    /// User action only (the 🤫 menu): this Mac's cleanup model from Hugging Face into <data>/models, checked
    /// against its SHA-256, then loaded. A second call while one runs does nothing.
    func downloadCleanup() async {
        guard !downloadingCleanup, let m = currentCleanupModel() else { return }
        downloadingCleanup = true
        cleanupDownloadFailed = false
        cleanupStatus = "Downloading the cleanup model…"
        defer { downloadingCleanup = false }
        do {
            let (tmp, response) = try await URLSession.shared.download(from: m.url)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpeechError("Download failed: \(response)") }
            let models = models
            try await Task.detached { try m.install(tmp, into: models) }.value  // hashing 1.3 GB stays off the main thread
        } catch {
            FileHandle.standardError.write(Data("cleanup model download: \(error)\n".utf8))
            cleanupDownloadFailed = true
            cleanupStatus = "Rules only (the download failed; try again from the 🤫 menu)"
            return
        }
        await loadCleanup()
    }

    private func saved(_ saving: Task<URL, Error>, _ run: inout Run) async -> String? {
        do { run.entry.audioPath = try await saving.value.path } catch {
            return "Could not save audio: \(error.localizedDescription)"
        }
        return nil
    }

    /// After the WAV, so the disk has answered once already. ponytail: still on the main thread; a disk that
    /// stalls again here holds it (Dictation's too-short and cancelled rows too).
    private func record(_ run: inout Run) {
        do { try history.add(run.entry) } catch { run.error = "Could not write history: \(error.localizedDescription)" }
    }

    private static func ms(_ samples: [Float]) -> Int { samples.count * 1000 / AudioStore.sampleRate }
}
