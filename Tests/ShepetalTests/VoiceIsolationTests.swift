import XCTest
import ShepetalCore
@testable import Shepetal

/// #75, Pavel's rule: on the Mac, always Voice Isolation, and never the Mic Mode picker. The model hears every
/// dictation through Apple's sound-isolation effect; the kept WAV stays the raw recording (rule 4).
final class VoiceIsolationTests: XCTestCase {
    private func db(_ x: [Float]) -> Float { 10 * log10(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }

    func testNoiseIsTakenOutAndTheLengthKept() {
        let raw = noise(db: -30, count: 32_000)
        let out = VoiceIsolation.apply(raw)
        XCTAssertEqual(out.count, raw.count, "the same 2 s, aligned: the effect's latency is taken out")
        XCTAssertLessThan(db(out), db(raw) - 10, "steady noise is not a voice")
        XCTAssertEqual(VoiceIsolation.apply([]), [])
    }

    @MainActor
    func testTheModelHearsIsolatedAudioAndTheWavKeepsTheRaw() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iso-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let raw = noise(db: -30, count: 32_000)
        let engine = FakeEngine("hello")
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let run = await pipeline.process(raw, engine: engine, context: { ("", "") }, sendPaste: { _ in })
        XCTAssertEqual(engine.heard.count, raw.count)
        XCTAssertLessThan(db(engine.heard), db(raw) - 10, "the model got the isolated audio")
        XCTAssertEqual(try AudioStore.read(URL(fileURLWithPath: run.entry.audioPath)), raw, "the kept WAV is the raw recording")
    }

    /// The picker is system UI that only `showSystemUserInterface(.microphoneModes)` opens, and Apple's voice
    /// processing would list Shepetal in it. Neither may appear in the app.
    func testNothingOpensTheMicModePickerOrTurnsOnVoiceProcessing() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Shepetal").standardizedFileURL
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(files.contains("Audio.swift"), dir.path)
        for f in files {
            let code = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                .components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for call in ["showSystemUserInterface", "setVoiceProcessingEnabled", "isVoiceProcessingEnabled = true"] {
                XCTAssertFalse(code.contains(call), "\(f) uses \(call)")
            }
        }
    }
}
