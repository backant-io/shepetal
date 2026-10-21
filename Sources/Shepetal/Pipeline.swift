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
    let models: URL  // the downloaded cleanup model's dir
    let dictionary: URL  // dictionary.txt in this pipeline's data dir
    /// Formatted or Raw per app (F33), read on every dictation. Tests pass their own UserDefaults suite.
    var appFormat = AppFormat()
    /// Writes a recording's WAV. Runs off the main thread: on Pavel's nearly full disk, while macOS purged
    /// space, one such write took 86 s, and fn, the menu and rule 8 froze with it (M-NS-1). Tests stall it.
    var writeAudio: @Sendable (_ samples: [Float], _ id: String) throws -> URL
    /// Settings' "Use the text around the cursor to clean up dictation" (F24, off by default), read at each
    /// dictation. Tests set it.
    var useFieldContext: () -> Bool = { UserDefaults.standard.bool(forKey: CleanupContext.settingKey) }
    /// F42's Settings toggle: a dictation that ends with "press enter" presses Return after a landed paste.
    var pressEnterCommand: () -> Bool = { UserDefaults.standard.bool(forKey: PressEnter.key) }
    /// Where Settings' style picks are read (F37). Tests pass a throwaway suite.
    var styleDefaults = UserDefaults.standard

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

    /// `app` is the frontmost app at dictation start (history, and the app's format, style and paste mode).
    /// `context` is the text around the cursor and the selection the paste replaces, read once: after cleanup, or
    /// before it when the text around the cursor is on (F24). `willPaste` runs right before the paste's own read of
    /// the field, after the last cancel check.
    /// `focusKept` says whether the window focused when the dictation started is still focused (nil: unknown),
    /// and `secureInput` names the app holding secure input. When focus moved or secure input is on, nothing is
    /// pasted and the text is left on the clipboard (rule 8). Focus is never moved back. The defaults skip them.
    /// `decided` gets the outcome (an error message, or nil when the text landed) as soon as it is known; the
    /// WAV and the history row can still be waiting on the disk then. `process` returns once both are written.
    func process(_ samples: [Float], engine: SpeechEngine?, app: AppContext = AppContext(),
                 context: () -> FocusedText.Context, willPaste: () -> Void = {},
                 focusKept: () -> Bool? = { nil }, secureInput: () -> String? = { nil },
                 sendPaste: (CGEvent) -> Void, decided: (String?) -> Void = { _ in }) async -> Run {
        let t0 = ProcessInfo.processInfo.systemUptime
        var run = Run(entry: HistoryEntry(id: UUID().uuidString, createdAt: Date(), outcome: .failed, audioPath: "",
                                          durationMs: Self.ms(samples), app: app.name, bundleId: app.bundleId, url: app.url))
        let id = run.entry.id, write = writeAudio
        let saving = Task.detached { try write(samples, id) }  // first, so the audio survives anything below
        let error = await transcribeAndInsert(samples, engine, t0, context, willPaste, focusKept, secureInput, sendPaste, &run)
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
                                     _ context: () -> FocusedText.Context, _ willPaste: () -> Void,
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
            let wav = store.url(run.entry.id)  // still being written: every engine works on the samples
            run.entry.rawText = try await engine.transcribe(heard, wav: wav)
        } catch {
            if Task.isCancelled { run.entry.outcome = .cancelled; return nil }  // Esc while transcribing
            return "Transcription failed: \(error.localizedDescription)"
        }
        // F24: with the text around the cursor on, the field is read now, once, so the cleanup model sees it. Rule 8
        // first: a field that no longer has the dictation's focus, or sits under secure input, is not read.
        var field: FocusedText.Context?
        if useFieldContext(), PasteGate.blocked(focusKept: focusKept(), secureInputApp: secureInput()) == nil { field = context() }
        let cleaned = await finishText(run.entry.rawText, bundleId: run.entry.bundleId, url: run.entry.url, context: field.map {
            CleanupContext(before: $0.before, after: $0.after, selected: $0.selected)
        } ?? .none)
        let command = pressEnterCommand() ? PressEnter.split(cleaned.text, raw: run.entry.rawText) : (text: cleaned.text, enter: false)
        run.entry.text = command.text
        run.cleanupModel = cleaned.usedModel ? cleanup?.name : nil
        run.readyMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        if Task.isCancelled { run.entry.outcome = .cancelled; return nil }  // Esc while transcribing: keep the text, insert nothing
        guard !run.entry.text.isEmpty else {
            let message = noSpeech(&run)
            return command.enter ? PressEnter.nothingToSend : message  // only "press enter" was said
        }
        // Rule 8 before the field is read: when the text is not pasted, the field that has focus now is not
        // where it goes. And again right before the paste: focus or secure input can change during the read.
        if let message = blocked(focusKept, secureInput, &run) { return message }
        willPaste()
        let (before, after, selected) = field ?? context()
        run.inserted = InsertionRules.fit(run.entry.text, before: before, after: after, selected: selected)
        if let message = blocked(focusKept, secureInput, &run) { return message }
        // F22: the app's paste mode. Rule 8 is asked again wherever the mode waits, and before Return (F42).
        let paste = await inserter.insert(run.inserted, mode: PasteMode.current(for: run.entry.bundleId), sendPaste: sendPaste,
                                          stillFocused: { PasteGate.blocked(focusKept: focusKept(), secureInputApp: secureInput()) == nil },
                                          pressReturn: command.enter)
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

    /// Everything between speech-to-text and insertion, shared by dictation and re-transcription (Hub), in the
    /// mode `appFormat` gives the app: `AppFormat.finish` (F33), with the style picked for the app's category (F37)
    /// and `context`, the text around the cursor for the cleanup model (F24; re-transcription has none). `bundleId`
    /// and `url` are the run's or the row's. InsertionRules fits the result to the cursor afterwards. Runs off the
    /// main thread.
    func finishText(_ raw: String, bundleId: String = "", url: String = "",
                    context: CleanupContext = .none) async -> (text: String, usedModel: Bool) {
        let model = cleanup, dictionary = dictionary, mode = appFormat.mode(for: bundleId)
        let style = Styles.chosen(bundleId: bundleId, url: url, styleDefaults)
        return await Task.detached {
            AppFormat.finish(raw, mode: mode, model: model, vocabulary: Vocabulary.load(dictionary), style: style, context: context)
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
    /// against its SHA-256, then loaded. A second call while one runs does nothing. Returns the notice for 🤫
    /// when the download fails.
    @discardableResult
    func downloadCleanup() async -> String? {
        guard !downloadingCleanup, let m = currentCleanupModel() else { return nil }
        downloadingCleanup = true
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
            cleanupStatus = "Rules only (the download failed; try again from the 🤫 menu)"
            return "Cleanup model download failed: check the internet connection and try again"  // the detail went to stderr
        }
        await loadCleanup()
        return nil
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
