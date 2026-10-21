import AppKit
import FluidAudio
import ShepetalCore

protocol SpeechEngine: AnyObject {
    var name: String { get }
    /// True when `transcribe` reads `wav`. Dictation then waits for the file; otherwise it is still being
    /// written while the samples are transcribed.
    var readsWav: Bool { get }
    /// `wav` is the saved recording holding the same samples.
    func transcribe(_ samples: [Float], wav: URL) async throws -> String
}

extension SpeechEngine {
    var readsWav: Bool { false }
}

struct SpeechError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }

    /// For the UI: our own messages pass as they are. Anything else (FluidAudio, CoreML, a failed process) can
    /// carry model names and paths, so it goes to the log and the user sees `fallback`.
    init(plain error: Error, _ fallback: String) {
        if let own = error as? SpeechError { self = own; return }
        NSLog("shepetal: speech: %@", String(describing: error))
        errorDescription = fallback
    }
}

enum Speech {
    /// The model for the selected languages (`speechRoute`), then the tier's fallback when that model is the
    /// tier's default. Never downloads anything.
    static func load(prefer: SpeechModel? = nil, languages: [String] = []) async throws -> SpeechEngine {
        let tier = currentModelTier()
        let route = speechRoute(languages: languages, tier: tier)
        var tried: [String] = []
        var models = [prefer ?? route.model]
        // A language only whisper knows gets no fallback: Parakeet would write it in the wrong language.
        if route.model == tier.primary, let f = tier.fallback, f != models[0] { models.append(f) }
        for model in models {
            do { return try await engine(for: model, language: route.language ?? "auto") } catch {
                tried.append("\(model.rawValue): \(error.localizedDescription)")  // not shown: logged below
            }
        }
        NSLog("shepetal: no speech model: %@", tried.joined(separator: "; "))  // names in the log, not the UI
        guard route.model == tier.primary else {
            let names = languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            throw SpeechError("On-device speech recognition for \(names.joined(separator: ", ")) is not installed")
        }
        throw SpeechError("On-device speech recognition is not available")
    }

    static func engine(for model: SpeechModel, language: String = "auto") async throws -> SpeechEngine {
        do {
            switch model {
            case .parakeetV3: return try await ParakeetEngine.load()
            case .whisperBaseEn, .whisperLargeV3Turbo: return try WhisperCppEngine(model, language: language)
            }
        } catch {
            throw SpeechError(plain: error, "On-device speech recognition could not start")
        }
    }
}

extension Paths {
    /// The personal dictionary, re-read on every dictation.
    static var dictionary: URL { root.appendingPathComponent("dictionary.txt") }
}

/// The 🤫 menu's Languages submenu and Dictionary item.
@MainActor
final class SpeechMenu: NSObject {
    /// Called when a language change needs another model.
    var reload: () -> Void = {}
    /// Shows an error next to 🤫.
    var fail: (String) -> Void = { _ in }

    /// BCP-47 codes; empty means automatic.
    var languages: [String] {
        get { UserDefaults.standard.stringArray(forKey: "languages") ?? [] }
        set {
            let before = speechRoute(languages: languages, tier: currentModelTier())
            UserDefaults.standard.set(newValue, forKey: "languages")
            if speechRoute(languages: newValue, tier: currentModelTier()) != before { reload() }
        }
    }

    func items() -> [NSMenuItem] {
        let menu = NSMenu()
        let auto = menu.addItem(withTitle: "Automatic", action: #selector(automatic), keyEquivalent: "")
        auto.target = self
        auto.state = languages.isEmpty ? .on : .off
        menu.addItem(.separator())
        let name = { (code: String) in Locale.current.localizedString(forLanguageCode: code) ?? code }
        for code in whisperLanguages.sorted(by: { name($0) < name($1) }) {
            let i = menu.addItem(withTitle: name(code), action: #selector(toggle(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = code
            i.state = languages.contains(code) ? .on : .off
        }
        let languagesItem = NSMenuItem(title: "Languages", action: nil, keyEquivalent: "")
        languagesItem.submenu = menu
        let dictionary = NSMenuItem(title: "Dictionary…", action: #selector(openDictionary), keyEquivalent: "")
        dictionary.target = self
        return [languagesItem, dictionary]
    }

    @objc private func automatic() { languages = [] }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        languages = languages.contains(code) ? languages.filter { $0 != code } : languages + [code]
    }

    /// Creates dictionary.txt with its header comment if needed and opens it in the default editor.
    @objc private func openDictionary() {
        do {
            try AudioStore.makeOwnerOnlyDirectory(Paths.root)
            try Vocabulary.create(Paths.dictionary)
            NSWorkspace.shared.open(Paths.dictionary)
        } catch {
            fail("Dictionary: \(error.localizedDescription)")
        }
    }

    /// Shows a notice next to 🤫.
    var notice: (String) -> Void = { _ in }
    private var downloadingBoost = false

    /// F39: the keyword model's download, offered once on-device speech recognition is there and only until the
    /// keyword model is. Whisper takes the dictionary as a prompt and needs none of it.
    func boostItem(speechInstalled: Bool = ParakeetEngine.isInstalled, booster: VocabularyBooster = KeywordBooster.shared) -> NSMenuItem? {
        guard speechInstalled, !booster.isInstalled else { return nil }
        let i = NSMenuItem(title: downloadingBoost ? "Downloading dictionary support…" : "Download dictionary support (about 100 MB)",
                           action: downloadingBoost ? nil : #selector(downloadBoost), keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func downloadBoost() {
        downloadingBoost = true
        notice("Downloading dictionary support…")
        Task {
            defer { downloadingBoost = false }
            do { try await KeywordBooster.download() } catch {
                fail("Download failed: " + (SpeechError(plain: error, "check the internet connection and try again").errorDescription ?? ""))
                return
            }
            notice("Dictionary support is ready")
        }
    }
}

/// Parakeet TDT 0.6B v3 through FluidAudio (CoreML, Neural Engine), from FluidAudio's model cache.
final class ParakeetEngine: SpeechEngine {
    let name = SpeechModel.parakeetV3.rawValue
    /// The model itself. A seam, so tests run without it.
    private let recognize: ([Float]) async throws -> ASRResult
    private let booster: VocabularyBooster
    private let dictionary: () -> Vocabulary

    static var directory: URL { AsrModels.defaultCacheDirectory(for: .v3) }
    static var isInstalled: Bool { AsrModels.modelsExist(at: directory, version: .v3) }

    init(recognize: @escaping ([Float]) async throws -> ASRResult, booster: VocabularyBooster = KeywordBooster.shared,
         dictionary: @escaping () -> Vocabulary = { Vocabulary.load(Paths.dictionary) }) {
        self.recognize = recognize
        self.booster = booster
        self.dictionary = dictionary
    }

    static func load() async throws -> ParakeetEngine {
        // Checked first so FluidAudio never fetches missing files on its own.
        guard isInstalled else { throw SpeechError("On-device speech recognition is not downloaded yet") }
        let models = try await AsrModels.load(from: directory, version: .v3)
        let asr = AsrManager()
        try await asr.loadModels(models)
        let layers = models.version.decoderLayers
        let engine = ParakeetEngine(recognize: { samples in
            var state = TdtDecoderState.make(decoderLayers: layers)
            return try await asr.transcribe(samples, decoderState: &state)
        })
        // The first inference compiles and warms the CoreML graph; do it before the user speaks.
        _ = try? await engine.transcribe([Float](repeating: 0, count: 16_000), wav: URL(fileURLWithPath: "/dev/null"))
        _ = await Task.detached { VoiceIsolation.apply([Float](repeating: 0, count: 16_000)) }.value  // the same for the effect
        return engine
    }

    /// FluidAudio deletes a model folder it cannot load and downloads it again on its own, unless its offline
    /// mode is on (#78). main.swift turns it on before anything loads; only `download()` lifts it.
    static func stayOffline() { ModelHub.offlineMode = true }

    /// User action only: about 470 MB from Hugging Face into FluidAudio's cache.
    static func download() async throws {
        ModelHub.offlineMode = false
        defer { stayOffline() }
        _ = try await AsrModels.download(version: .v3)
    }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        // A hold can end with under 300 ms of audio while the mic was still opening; Parakeet refuses that.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: AudioStore.sampleRate)
        let heard = MicAudio.padded(samples, to: minimum)
        let result: ASRResult
        do { result = try await recognize(heard) } catch {
            throw SpeechError(plain: error, "On-device speech recognition could not read this recording")
        }
        // The dictionary (F39, #30), read fresh for every dictation like the replacements. The load's warm-up
        // gets here too, with no timings, so the keyword model loads before the user speaks.
        let terms = dictionary().promptTerms
        guard !terms.isEmpty, booster.isInstalled else { return result.text }
        return await booster.boost(result.text, timings: result.tokenTimings ?? [], samples: heard, terms: terms) ?? result.text
    }
}

/// Parakeet takes no prompt, so the dictionary reaches it afterwards (F39, #30): a small keyword model listens to
/// the same audio for the dictionary's words, and rescoring writes the ones it hears into Parakeet's text.
protocol VocabularyBooster: AnyObject, Sendable {
    /// False until the user downloads the keyword model. Then nothing is boosted and nothing is fetched.
    var isInstalled: Bool { get }
    /// The rescored text, or nil to keep the model's own.
    func boost(_ text: String, timings: [TokenTiming], samples: [Float], terms: [String]) async -> String?
}

/// FluidAudio's CTC 110M keyword model and its VocabularyBoostingSession. Never downloads on its own.
actor KeywordBooster: VocabularyBooster {
    static let shared = KeywordBooster()
    static var directory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }

    nonisolated let directory: URL
    private var models: CtcModels?
    private var session: (terms: [String], session: VocabularyBoostingSession)?

    init(directory: URL = KeywordBooster.directory) { self.directory = directory }

    nonisolated var isInstalled: Bool { CtcModels.modelsExist(at: directory) }

    func boost(_ text: String, timings: [TokenTiming], samples: [Float], terms: [String]) async -> String? {
        guard isInstalled else { return nil }  // checked first so FluidAudio never fetches missing files
        do {
            if self.models == nil { self.models = try await CtcModels.load(from: directory) }
            guard let models = self.models else { return nil }
            if session?.terms != terms {  // rebuilt only when the dictionary changes
                let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
                session = (terms, try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models))
            }
            return await session?.session.rescore(text: text, tokenTimings: timings, audioSamples: samples)?.text
        } catch {
            NSLog("shepetal: dictionary boost: %@", String(describing: error))  // the plain text goes in
            return nil
        }
    }

    /// User action only: about 100 MB into FluidAudio's cache. Offline mode is lifted for it alone, as for Parakeet.
    static func download(to directory: URL = KeywordBooster.directory) async throws {
        ModelHub.offlineMode = false
        defer { ParakeetEngine.stayOffline() }
        try await CtcModels.download(to: directory)
    }
}

/// The docs/models.md fallback: whisper.cpp's whisper-cli on the saved WAV.
/// ponytail: one process per dictation reloads the model (0.35 to 1.1 s here); keep a whisper.cpp
/// server or link libwhisper if the fallback has to meet the 700 ms bar.
/// Looks in <data>/models (whisper.cpp/whisper-cli and ggml-*.bin); SHEPETAL_WHISPER_CLI and
/// SHEPETAL_WHISPER_MODEL override the paths.
final class WhisperCppEngine: SpeechEngine {
    let name: String
    let readsWav = true  // whisper-cli reads the WAV file
    private let cli: URL
    private let model: URL
    private let language: String

    /// `language` is whisper's `-l` value: a code, or "auto".
    init(_ m: SpeechModel, language: String = "auto") throws {
        let env = ProcessInfo.processInfo.environment
        cli = env["SHEPETAL_WHISPER_CLI"].map { URL(fileURLWithPath: $0) }
            ?? Paths.models.appendingPathComponent("whisper.cpp/whisper-cli")
        model = env["SHEPETAL_WHISPER_MODEL"].map { URL(fileURLWithPath: $0) }
            ?? Paths.models.appendingPathComponent("\(m.rawValue).bin")  // not shown: a path
        self.language = language
        name = model.deletingPathExtension().lastPathComponent
        for url in [cli, model] where !FileManager.default.fileExists(atPath: url.path) {
            NSLog("shepetal: %@ not found", url.path)
            throw SpeechError("The alternative engine is not installed")
        }
    }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        // The dictionary hint (F39), read fresh for every dictation like the replacements.
        let args = whisperArguments(model: model.path, wav: wav.path, language: language,
                                    vocabulary: Vocabulary.load(Paths.dictionary))
        do { return try await run(cli, args) } catch {
            throw SpeechError(plain: error, "The alternative engine could not read this recording")
        }
    }

    private func run(_ cli: URL, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = cli
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw SpeechError("The alternative engine stopped with code \(p.terminationStatus)") }
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
        }.value
    }
}
