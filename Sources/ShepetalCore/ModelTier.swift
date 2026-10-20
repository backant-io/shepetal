import Foundation

public enum SpeechModel: String, Equatable {
    case parakeetV3 = "parakeet-tdt-0.6b-v3"          // FluidAudio CoreML, Apple Silicon only
    case whisperBaseEn = "ggml-base.en-q5_1"          // whisper.cpp
    case whisperLargeV3Turbo = "ggml-large-v3-turbo-q5_0"  // whisper.cpp
}

public struct ModelTier: Equatable {
    public let primary: SpeechModel
    public let fallback: SpeechModel?
}

/// The Mac rows of the tier table in docs/models.md.
/// Fallbacks all run on whisper.cpp so the Mac needs one fallback runtime.
public func modelTier(appleSilicon: Bool, ramGB: Int) -> ModelTier {
    guard appleSilicon else { return ModelTier(primary: .whisperBaseEn, fallback: nil) }
    if ramGB < 16 { return ModelTier(primary: .parakeetV3, fallback: .whisperBaseEn) }
    return ModelTier(primary: .parakeetV3, fallback: .whisperLargeV3Turbo)
}

/// This machine's tier.
public func currentModelTier() -> ModelTier {
    #if arch(arm64)
    let arm = true
    #else
    let arm = false
    #endif
    return modelTier(appleSilicon: arm, ramGB: Int(ProcessInfo.processInfo.physicalMemory >> 30))
}

// MARK: languages

/// The 25 languages Parakeet TDT 0.6B v3 transcribes, from NVIDIA's model card:
/// https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 ("Supported Languages").
public let parakeetLanguages: Set<String> = [
    "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
    "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
]

/// The language codes whisper takes for `-l`, from `LANGUAGES` in
/// https://github.com/openai/whisper/blob/main/whisper/tokenizer.py. The 🤫 menu offers these.
public let whisperLanguages = [
    "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it", "id", "hi",
    "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr", "bg", "lt", "la",
    "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy",
    "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be",
    "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
    "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
]

/// Which model transcribes, and the whisper `-l` value when it is whisper.
public struct SpeechRoute: Equatable {
    public let model: SpeechModel
    public let language: String?  // nil for Parakeet, which detects the language itself

    public init(model: SpeechModel, language: String?) {
        self.model = model
        self.language = language
    }
}

/// `selected` holds BCP-47 tags ("de", "pt-BR"); empty means automatic.
/// Parakeet when it covers every selected language (and the tier has it), else whisper large-v3-turbo,
/// told the language when there is exactly one.
public func speechRoute(languages selected: [String], tier: ModelTier) -> SpeechRoute {
    let codes = Set(selected.map { $0.split(separator: "-").first.map { $0.lowercased() } ?? "" })
    if tier.primary == .parakeetV3, codes.isSubset(of: parakeetLanguages) {
        return SpeechRoute(model: .parakeetV3, language: nil)
    }
    let language = codes.count == 1 ? codes.first! : "auto"
    // English only (or automatic) without Apple Silicon: the tier's small English model is enough.
    if tier.primary == .whisperBaseEn, codes.isSubset(of: ["en"]) { return SpeechRoute(model: .whisperBaseEn, language: language) }
    return SpeechRoute(model: .whisperLargeV3Turbo, language: language)
}

/// whisper-cli's arguments for one recording. The dictionary hint goes in `--prompt`:
/// - in reverse priority order, because whisper.cpp keeps only the last ~224 prompt tokens, so starred entries sit at the end;
/// - shaped like a sentence, because whisper copies the prompt's style: a bare lowercase word list made it
///   drop casing and punctuation on an e2e clip.
public func whisperArguments(model: String, wav: String, language: String, vocabulary: Vocabulary) -> [String] {
    var args = ["-m", model, "-f", wav, "-l", language, "-nt", "-np"]
    let terms = vocabulary.promptTerms
    if !terms.isEmpty { args += ["--prompt", "Glossary: " + terms.reversed().joined(separator: ", ") + "."] }
    return args
}
