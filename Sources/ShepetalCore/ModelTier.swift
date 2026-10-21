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
    let codes = Set(languageCodes(selected))
    if tier.primary == .parakeetV3, codes.isSubset(of: parakeetLanguages) {
        return SpeechRoute(model: .parakeetV3, language: nil)
    }
    let language = codes.count == 1 ? codes.first! : "auto"
    // English only (or automatic) without Apple Silicon: the tier's small English model is enough.
    if tier.primary == .whisperBaseEn, codes.isSubset(of: ["en"]) { return SpeechRoute(model: .whisperBaseEn, language: language) }
    return SpeechRoute(model: .whisperLargeV3Turbo, language: language)
}

/// The language codes of BCP-47 tags ("pt-BR" is "pt"), in the order chosen, each once.
public func languageCodes(_ selected: [String]) -> [String] {
    var seen = Set<String>()
    return selected.compactMap { $0.split(separator: "-").first.map { $0.lowercased() } }.filter { seen.insert($0).inserted }
}

/// The language whisper is told when several are chosen: the most likely of the chosen ones, even when a language
/// outside them ranks first. whisper alone keeps only its top guess, which may be none of them (#31). A tie goes to
/// the one chosen first. nil when none is chosen: whisper then detects the language itself.
public func pickLanguage(probs: [String: Float], allowed: [String]) -> String? {
    var best: String?
    for code in allowed where best == nil || probs[code, default: 0] > probs[best!, default: 0] { best = code }
    return best
}

/// Languages Apple's text language recognizer cannot tell: it read Estonian as Finnish (0.98), Maltese as
/// Norwegian (0.94), Slovenian as Croatian (0.88), Latvian and Lithuanian as Finnish and Slovak.
/// With one of them chosen, a dictation in it would look like the wrong language, so there is no check.
public let languagesTextCannotTell: Set<String> = ["et", "lv", "lt", "mt", "sl"]

/// The language a dictation came out in when it is not one of the chosen ones, for the hint next to 🤫 (F12).
/// Only for Parakeet, which takes no language and writes whatever it heard; whisper is told one of them.
/// `hypotheses` are the text recognizer's, by BCP-47 tag. nil when nothing is chosen, when the text is too short
/// to tell (it read "Redis." as French), when the recognizer is not sure, or when it cannot tell a chosen language.
public func wrongLanguage(hypotheses: [String: Double], words: Int, chosen: [String]) -> String? {
    let chosen = Set(languageCodes(chosen))
    guard !chosen.isEmpty, chosen.isDisjoint(with: languagesTextCannotTell), words >= 3,
          let (tag, p) = hypotheses.max(by: { $0.value < $1.value }), p >= 0.9,
          let code = languageCodes([tag]).first, !chosen.contains(code) else { return nil }
    return code
}

/// The dictionary hint whisper gets as its prompt, nil for an empty dictionary:
/// - in reverse priority order, because whisper.cpp keeps only the last ~224 prompt tokens, so starred entries sit at the end;
/// - shaped like a sentence, because whisper copies the prompt's style: a bare lowercase word list made it
///   drop casing and punctuation on an e2e clip.
public func whisperPrompt(_ vocabulary: Vocabulary) -> String? {
    let terms = vocabulary.promptTerms
    return terms.isEmpty ? nil : "Glossary: " + terms.reversed().joined(separator: ", ") + "."
}
