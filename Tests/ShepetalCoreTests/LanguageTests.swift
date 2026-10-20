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

    func testWhisperArguments() {
        let base = ["-m", "/m.bin", "-f", "/a.wav"]
        XCTAssertEqual(whisperArguments(model: "/m.bin", wav: "/a.wav", language: "ja", vocabulary: Vocabulary()),
                       base + ["-l", "ja", "-nt", "-np"], "no --prompt for an empty dictionary")
        XCTAssertEqual(whisperArguments(model: "/m.bin", wav: "/a.wav", language: "auto", vocabulary: Vocabulary("# only a comment")),
                       base + ["-l", "auto", "-nt", "-np"])

        let args = whisperArguments(model: "/m.bin", wav: "/a.wav", language: "auto",
                                    vocabulary: Vocabulary("Kubernetes\n*Shepetal\nk eight s => k8s"))
        XCTAssertEqual(Array(args.prefix(8)), base + ["-l", "auto", "-nt", "-np"])
        // whisper.cpp keeps the end of a long prompt, so the highest priority entry goes last.
        XCTAssertEqual(Array(args.suffix(2)), ["--prompt", "Glossary: k eight s, Kubernetes, Shepetal."])

        let many = Vocabulary((0..<300).map { "word\($0)" }.joined(separator: "\n"))
        let prompt = whisperArguments(model: "m", wav: "w", language: "auto", vocabulary: many).last!
        XCTAssertEqual(prompt.components(separatedBy: ", ").count, 200)
        XCTAssertTrue(prompt.hasSuffix(" word0."))
        XCTAssertFalse(prompt.contains("word200"))
    }
}
