import XCTest
@testable import ShepetalCore

/// Which model hears which languages (F12). Parakeet only knows 25 European languages, so routing
/// Japanese to it gives wrong text; whisper needs `-l` or it guesses the language from the first 30 s.
final class LanguageTests: XCTestCase {
    let mac24 = modelTier(appleSilicon: true, ramGB: 24)
    let mac8 = modelTier(appleSilicon: true, ramGB: 8)
    let intel = modelTier(appleSilicon: false, ramGB: 16)

    func testEmptySelectionUsesTierPrimary() {
        XCTAssertEqual(speechRoute(languages: [], tier: mac24), SpeechRoute(model: mac24.primary, language: nil))
        XCTAssertEqual(speechRoute(languages: [], tier: mac8), SpeechRoute(model: .parakeetV3, language: nil))
    }

    func testEuropeanSetStaysOnParakeet() {
        XCTAssertEqual(speechRoute(languages: ["de", "fr"], tier: mac24), SpeechRoute(model: .parakeetV3, language: nil))
        XCTAssertEqual(speechRoute(languages: ["pt-BR", "EN-gb", "uk"], tier: mac8).model, .parakeetV3)
        XCTAssertEqual(parakeetLanguages.count, 25)
        XCTAssertTrue(parakeetLanguages.isSubset(of: Set(whisperLanguages)), "the menu offers every Parakeet language")
    }

    func testJapaneseRoutesToWhisperWithJa() {
        XCTAssertEqual(speechRoute(languages: ["ja"], tier: mac24), SpeechRoute(model: .whisperLargeV3Turbo, language: "ja"))
        XCTAssertEqual(speechRoute(languages: ["ja-JP"], tier: mac8), SpeechRoute(model: .whisperLargeV3Turbo, language: "ja"))
    }

    func testMixedSetUsesWhisperAuto() {
        XCTAssertEqual(speechRoute(languages: ["en", "ja"], tier: mac24), SpeechRoute(model: .whisperLargeV3Turbo, language: "auto"))
        // Two tags of one language are one language.
        XCTAssertEqual(speechRoute(languages: ["zh-Hans", "zh-Hant"], tier: mac24).language, "zh")
    }

    func testNoAppleSiliconAlwaysWhisper() {
        XCTAssertEqual(speechRoute(languages: [], tier: intel), SpeechRoute(model: .whisperBaseEn, language: "auto"))
        XCTAssertEqual(speechRoute(languages: ["en"], tier: intel), SpeechRoute(model: .whisperBaseEn, language: "en"))
        XCTAssertEqual(speechRoute(languages: ["de"], tier: intel), SpeechRoute(model: .whisperLargeV3Turbo, language: "de"))
        XCTAssertEqual(speechRoute(languages: ["de", "fr"], tier: intel), SpeechRoute(model: .whisperLargeV3Turbo, language: "auto"))
    }

    // The dictionary reaches whisper as its prompt. whisper.cpp keeps the end of a long prompt, so the highest
    // priority entry goes last; a sentence shape keeps whisper's casing and punctuation.
    func testWhisperPrompt() {
        XCTAssertNil(whisperPrompt(Vocabulary()), "no prompt for an empty dictionary")
        XCTAssertNil(whisperPrompt(Vocabulary("# only a comment")))
        XCTAssertEqual(whisperPrompt(Vocabulary("Kubernetes\n*Shepetal\nk eight s => k8s")), "Glossary: k eight s, Kubernetes, Shepetal.")

        let many = Vocabulary((0..<300).map { "word\($0)" }.joined(separator: "\n"))
        let prompt = whisperPrompt(many)!
        XCTAssertEqual(prompt.components(separatedBy: ", ").count, 200)
        XCTAssertTrue(prompt.hasSuffix(" word0."))
        XCTAssertFalse(prompt.contains("word200"))
    }

    func testLanguageCodesKeepTheChosenOrderOnce() {
        XCTAssertEqual(languageCodes(["ja-JP", "EN-gb", "ja", "pt-BR"]), ["ja", "en", "pt"])
        XCTAssertEqual(languageCodes([]), [])
    }

    // #31: with English and Japanese chosen, whisper alone writes Chinese when it hears Chinese as likeliest.
    // It must be told the likeliest chosen language instead.
    func testPickLanguageKeepsTheBestChosenOneWhenAnotherRanksFirst() {
        let probs: [String: Float] = ["zh": 0.62, "ja": 0.30, "en": 0.05, "ko": 0.03]
        XCTAssertEqual(pickLanguage(probs: probs, allowed: ["en", "ja"]), "ja")
        XCTAssertEqual(pickLanguage(probs: probs, allowed: ["ja", "en"]), "ja", "the order chosen does not beat the probabilities")
        XCTAssertEqual(pickLanguage(probs: probs, allowed: ["en", "ko"]), "en")
        XCTAssertEqual(pickLanguage(probs: probs, allowed: ["zh", "en"]), "zh", "the top language when it is chosen")
    }

    func testPickLanguageTieGoesToTheFirstChosen() {
        XCTAssertEqual(pickLanguage(probs: ["de": 0.4, "fr": 0.4, "it": 0.2], allowed: ["fr", "de"]), "fr")
        XCTAssertEqual(pickLanguage(probs: ["de": 0.4, "fr": 0.4, "it": 0.2], allowed: ["de", "fr"]), "de")
        XCTAssertEqual(pickLanguage(probs: [:], allowed: ["uk", "ru"]), "uk", "no probabilities: the first chosen")
    }

    func testPickLanguageWithOneOrNoneChosen() {
        XCTAssertEqual(pickLanguage(probs: ["zh": 0.9, "ja": 0.1], allowed: ["ja"]), "ja", "one chosen language is always it")
        XCTAssertNil(pickLanguage(probs: ["zh": 0.9], allowed: []), "none chosen: whisper detects on its own")
    }

    // Parakeet takes no language, so a dictation in another one comes out in it; the hint says so.
    func testWrongLanguageWhenTheTextIsClearlyInAnother() {
        XCTAssertEqual(wrongLanguage(hypotheses: ["es": 0.99, "pt": 0.01], words: 9, chosen: ["de", "fr"]), "es")
        XCTAssertEqual(wrongLanguage(hypotheses: ["zh-Hans": 0.97], words: 5, chosen: ["de"]), "zh", "the tag's language")
    }

    func testNoWrongLanguageWhenItFitsOrCannotBeTold() {
        XCTAssertNil(wrongLanguage(hypotheses: ["de": 0.99], words: 9, chosen: ["de", "fr"]), "a chosen language")
        XCTAssertNil(wrongLanguage(hypotheses: ["pt": 0.99], words: 9, chosen: ["pt-BR"]), "a chosen tag's language")
        XCTAssertNil(wrongLanguage(hypotheses: ["es": 0.99], words: 9, chosen: []), "Automatic")
        XCTAssertNil(wrongLanguage(hypotheses: ["fr": 0.95], words: 2, chosen: ["en"]), "too short to tell")
        XCTAssertNil(wrongLanguage(hypotheses: ["es": 0.6, "pt": 0.4], words: 9, chosen: ["de"]), "not sure")
        XCTAssertNil(wrongLanguage(hypotheses: [:], words: 9, chosen: ["de"]))
        // The recognizer reads Estonian as Finnish, so an Estonian speaker would always see the hint.
        XCTAssertNil(wrongLanguage(hypotheses: ["fi": 0.98], words: 7, chosen: ["et", "en"]))
        XCTAssertTrue(languagesTextCannotTell.isSubset(of: parakeetLanguages))
    }
}
