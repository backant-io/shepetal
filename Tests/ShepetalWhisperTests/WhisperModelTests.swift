import Foundation
import XCTest
import ShepetalWhisper

/// The real whisper.cpp model in process (F12, #31). Set SHEPETAL_WHISPER_MODEL to ggml-large-v3-turbo-q5_0.bin
/// (scripts/e2e-mac.sh downloads it into bench/.cache/whisper) to run these; without it they are skipped, and the
/// skip shows in the test output. The speech is made with `say` into a temporary file: nothing is played.
final class WhisperModelTests: XCTestCase {
    private static var loaded: WhisperModel?

    private func model() throws -> WhisperModel {
        if let m = Self.loaded { return m }
        guard let path = ProcessInfo.processInfo.environment["SHEPETAL_WHISPER_MODEL"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("SHEPETAL_WHISPER_MODEL is not set to a whisper model file")
        }
        let m = try WhisperModel(path: path)
        guard m.multilingual else { throw XCTSkip("\(m.name) knows English only") }
        Self.loaded = m
        return m
    }

    /// 16 kHz mono samples of `text` spoken by `voice`.
    private func speech(_ voice: String, _ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "--file-format=WAVE", "--data-format=LEI16@16000", "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("the \(voice) voice is not installed") }
        let data = try Data(contentsOf: url)
        guard let data_ = data.range(of: Data("data".utf8)) else { throw XCTSkip("no data chunk in say's WAV") }
        return stride(from: data_.upperBound + 4, to: data.count - 1, by: 2).map {
            Float(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)) / 32768
        }
    }

    private let japanese = "明日の会議は午後三時からです。資料を準備してください。"

    // Both chosen languages are heard as themselves.
    func testEnglishAndJapaneseChosenEachComesOutInItsOwn() throws {
        let m = try model()
        let ja = try m.transcribe(speech("Kyoko", japanese), languages: ["en", "ja"], prompt: nil)
        XCTAssertEqual(ja.language, "ja")
        XCTAssertTrue(ja.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) },
                      "Japanese text: \(ja.text)")
        let en = try m.transcribe(speech("Samantha", "Please send the quarterly report to the design team before Friday."),
                                  languages: ["en", "ja"], prompt: nil)
        XCTAssertEqual(en.language, "en")
        XCTAssertTrue(en.text.lowercased().contains("quarterly report"), en.text)
    }

    // #31: whisper's own top guess is outside the chosen languages, and it must not be the one it is told.
    // (Told English, large-v3-turbo still writes this clip in Japanese: the told language decides between close
    // ones, such as Japanese and Chinese, not what the speaker said.)
    func testALanguageOutsideTheChosenOnesIsNeverUsed() throws {
        let m = try model()
        let samples = try speech("Kyoko", japanese)
        let probs = try m.languageProbabilities(samples)
        XCTAssertEqual(probs.max { $0.value < $1.value }?.key, "ja", "whisper hears Japanese first")
        let (en, de) = (probs["en"] ?? 0, probs["de"] ?? 0)
        XCTAssertEqual(try m.transcribe(samples, languages: ["en", "de"], prompt: nil).language, en >= de ? "en" : "de",
                       "the likelier of the chosen ones: \(en) English, \(de) German")
        XCTAssertEqual(try m.transcribe(samples, languages: [], prompt: nil).language, "ja", "none chosen: whisper's own guess")
    }

    // A quick hold gives under 1 s. whisper.cpp used to skip that ("input is too short"); since #2065 only under
    // 100 ms, so the samples go in as they are.
    func testShortAudioIsStillTranscribed() throws {
        let m = try model()
        let samples = try speech("Samantha", "Yes.")
        XCTAssertLessThan(samples.count, 16_000)
        XCTAssertTrue(try m.transcribe(samples, languages: ["en"], prompt: nil).text.lowercased().contains("yes"))
    }
}
