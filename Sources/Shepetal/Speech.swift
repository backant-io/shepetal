import AppKit
import FluidAudio
import NaturalLanguage
import ShepetalCore
import ShepetalWhisper

protocol SpeechEngine: AnyObject {
    var name: String { get }
    /// `wav` is the saved recording holding the same samples.
    func transcribe(_ samples: [Float], wav: URL) async throws -> String
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
    /// tier's default. Whisper gets the languages, to pick from. Never downloads anything.
    static func load(prefer: SpeechModel? = nil, languages: [String] = []) async throws -> SpeechEngine {
        let tier = currentModelTier()
        let route = speechRoute(languages: languages, tier: tier)
        var tried: [String] = []
        var models = [prefer ?? route.model]
        // A language only whisper knows gets no fallback: Parakeet would write it in the wrong language.
        if route.model == tier.primary, let f = tier.fallback, f != models[0] { models.append(f) }
        for model in models {
            do { return try await engine(for: model, languages: languages) } catch {
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

    /// `languages` are the chosen BCP-47 tags, which only whisper takes; none lets it detect the language.
    static func engine(for model: SpeechModel, languages: [String] = []) async throws -> SpeechEngine {
        do {
            switch model {
            case .parakeetV3: return try await ParakeetEngine.load()
            case .whisperBaseEn, .whisperLargeV3Turbo: return try await WhisperEngine.load(model, languages: languages)
            }
        } catch {
            throw SpeechError(plain: error, "On-device speech recognition could not start")
        }
    }

    /// F12: the hint next to 🤫 when a dictation came out in a language that is not one of the chosen ones. Only
    /// when they route to Parakeet, which takes no language; whisper is told one of them. nil when the text fits.
    static func wrongLanguageHint(_ text: String, languages: [String], tier: ModelTier = currentModelTier()) -> String? {
        guard speechRoute(languages: languages, tier: tier).model == .parakeetV3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let code = wrongLanguage(hypotheses: Dictionary(uniqueKeysWithValues: hypotheses.map { ($0.key.rawValue, $0.value) }),
                                       words: text.split(whereSeparator: \.isWhitespace).count, chosen: languages) else { return nil }
        let language = Locale.current.localizedString(forLanguageCode: code) ?? code
        return "This sounded like \(language), which is not in your Languages"
    }
}

extension Paths {
    /// The personal dictionary, re-read on every dictation.
    static var dictionary: URL { root.appendingPathComponent("dictionary.txt") }
}

/// The 🤫 menu's Languages submenu, and Settings' Dictionary… button.
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

    func languagesItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.autoenablesItems = false  // every item is enabled (#207)
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
        return languagesItem
    }

    @objc private func automatic() { languages = [] }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        languages = languages.contains(code) ? languages.filter { $0 != code } : languages + [code]
    }

    /// Creates dictionary.txt with its header comment if needed and opens it in the default editor.
    func openDictionary() {
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
    /// F39: the keyword model, its download and the dictionary it listens for. Seams, so tests fetch nothing and
    /// read no dictionary.txt of the user's.
    var booster: VocabularyBooster = KeywordBooster.shared
    var downloadBooster: () async throws -> Void = { try await KeywordBooster.download() }
    var dictionary: () -> Vocabulary = { Vocabulary.load(Paths.dictionary) }
    private var downloadingBoost = false

    /// F39: what the 🤫 menu offers for the keyword model (`MenuState.dictionarySupport`). Only with on-device
    /// speech recognition there (whisper takes the dictionary as a prompt and needs none of it), only with words in
    /// the dictionary (without them the menu stays as short as #210 left it), and only until the keyword model is.
    func dictionarySupport(speechInstalled: Bool = ParakeetEngine.isInstalled) -> DictionarySupport? {
        if downloadingBoost { return .downloading }
        guard speechInstalled, !booster.isInstalled, !dictionary().promptTerms.isEmpty else { return nil }
        return .offered
    }

    /// The menu's Download dictionary support. nil while a download already runs.
    @discardableResult
    func downloadBoost() -> Task<Void, Never>? {
        guard !downloadingBoost else { return nil }
        downloadingBoost = true
        notice("Downloading dictionary support…")
        return Task {
            defer { downloadingBoost = false }
            do { try await downloadBooster() } catch {
                fail("Download failed: " + (SpeechError(plain: error, "check the internet connection and try again").errorDescription ?? ""))
                return
            }
            // Loads the keyword model now, as Parakeet's warm-up does at launch, so the next dictation does not wait.
            let terms = dictionary().promptTerms
            if !terms.isEmpty { _ = await booster.boost("", timings: [], samples: [Float](repeating: 0, count: 16_000), terms: terms) }
            notice("Dictionary support is ready")
        }
    }
}

/// The keyword model's line in the 🤫 menu (F39).
enum DictionarySupport { case offered, downloading }

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
        guard !terms.isEmpty, booster.isInstalled, KeywordBooster.knowsTheLanguage(of: result.text) else { return result.text }
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
    /// How close Parakeet's word must be to a dictionary term to be replaced. FluidAudio's own 0.52 wrote "edits" as
    /// "Redis" and "percent" as "Vercel" on bench/fixtures; 0.6 still wrote "edits" as "Redis", 0.8 missed
    /// "Postgres". bench/fluid uses the same values (docs/models.md).
    static let minSimilarity: Float = 0.7
    /// No acoustic-only rescue, which replaces words that look nothing like the term: with only "dentist" in the
    /// dictionary it wrote "copy the finance lead" as "copy the dentist" in scripts/e2e-mac.sh.
    static let config = VocabularyRescorer.Config(spotterRescueEnabled: false)
    static var directory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }

    /// The keyword model knows English only. On "Las redes sociales están llenas de ruido" it wrote "Las Redis
    /// sociales", so a dictation clearly in another language keeps Parakeet's text (docs/models.md). Short ones are
    /// still boosted: the recognizer reads "Redis." alone as French (0.52) and "Postgres." as German (0.20).
    /// ponytail: all or nothing per dictation; check each replaced word against the language if non-English
    /// dictations need their terms too.
    static func knowsTheLanguage(of text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, p) = recognizer.languageHypotheses(withMaximum: 1).first else { return true }
        return language == .english || p < 0.9
    }

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
                let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) },
                                                         minSimilarity: Self.minSimilarity)
                session = (terms, try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models, config: Self.config))
            }
            guard let out = await session?.session.rescore(text: text, tokenTimings: timings, audioSamples: samples),
                  out.wasModified else { return nil }
            return Self.replacing(out.replacements.compactMap { r in
                r.shouldReplace ? r.replacementWord.map { (r.originalWord, $0) } : nil
            }, in: text)
        } catch {
            NSLog("shepetal: dictionary boost: %@", String(describing: error))  // the plain text goes in
            return nil
        }
    }

    /// FluidAudio rebuilds its rescored text from its words, and a word it replaces loses its punctuation
    /// ("postgars." came back as "Postgres"). So the terms go into the model's own text instead: the original
    /// phrase without its punctuation, whole words only, first occurrence.
    /// ponytail: the first occurrence, not the one the keyword model heard; both are the same words.
    static func replacing(_ replacements: [(original: String, term: String)], in text: String) -> String {
        replacements.reduce(text) { text, r in
            let phrase = r.original.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            let pattern = #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?!\w)"#
            guard !phrase.isEmpty, let range = text.range(of: pattern, options: .regularExpression) else { return text }
            return text.replacingCharacters(in: range, with: r.term)
        }
    }

    /// User action only: about 100 MB into FluidAudio's cache. Offline mode is lifted for it alone, as for Parakeet.
    static func download(to directory: URL = KeywordBooster.directory) async throws {
        ModelHub.offlineMode = false
        defer { ParakeetEngine.stayOffline() }
        try await CtcModels.download(to: directory)
    }
}

/// The docs/models.md alternative engine: whisper.cpp in this process (ShepetalWhisper), the model loaded once and
/// kept, so a dictation no longer waits for whisper-cli to reload it (#11). It works on the samples, not the WAV.
/// Looks in <data>/models for ggml-*.bin; SHEPETAL_WHISPER_MODEL overrides the path.
final class WhisperEngine: SpeechEngine {
    let name: String
    private let model: WhisperModel
    private let languages: [String]
    private let lock = NSLock()
    private var told: String?
    /// The language whisper was told for the last recording, for the e2e check.
    var lastLanguage: String? { lock.withLock { told } }

    /// `languages` are the chosen BCP-47 tags: whisper is told the one language, or the likeliest of several (#31).
    init(model: WhisperModel, languages: [String]) {
        self.model = model
        self.languages = languageCodes(languages)
        name = model.name
    }

    static func load(_ m: SpeechModel, languages: [String] = []) async throws -> WhisperEngine {
        let path = ProcessInfo.processInfo.environment["SHEPETAL_WHISPER_MODEL"]
            ?? Paths.models.appendingPathComponent("\(m.rawValue).bin").path  // not shown: a path
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("shepetal: %@ not found", path)
            throw SpeechError("The alternative engine is not installed")
        }
        let model = try await Task.detached { try WhisperModel(path: path) }.value
        // The first run sets up the Metal kernels; do it before the user speaks. Language detection runs the encoder
        // and one decoder step: a whole transcription of silence took about 15 s here, retrying at every temperature.
        _ = await Task.detached { try? model.languageProbabilities([Float](repeating: 0, count: 16_000)) }.value
        return WhisperEngine(model: model, languages: languages)
    }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        // The dictionary hint (F39), read fresh for every dictation like the replacements.
        let prompt = whisperPrompt(Vocabulary.load(Paths.dictionary))
        do {
            let out = try await Task.detached { [model, languages] in
                try model.transcribe(samples, languages: languages, prompt: prompt)
            }.value
            lock.withLock { told = out.language }
            return out.text
        } catch {
            throw SpeechError(plain: error, "The alternative engine could not read this recording")
        }
    }
}
