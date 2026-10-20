import Foundation
import XCTest

/// No model name in any string the Mac app shows. Scans every string literal in Sources/Shepetal (the app
/// shell) and fails on a model or runtime name, or on a model name put in at run time. Log lines (NSLog),
/// lines marked "// not shown", comments, file paths and environment
/// variable names are exempt: those are not shown in the UI. E2E.swift is the test harness's JSON output.
final class ModelNameTests: XCTestCase {
    private static let names = try! NSRegularExpression(pattern: "parakeet|whisper|ggml|tdt|fluidaudio|large-v3|base\\.en|qwen|gemma|llama",
                                                        options: .caseInsensitive)
    /// An engine or model name put into a string at run time ("Model: \\(e.name)").
    private static let interpolated = try! NSRegularExpression(pattern: #"\\\([^()]*\.(name|model|rawValue)\)"#)
    private static let literal = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
    /// Paths and variable names, never shown.
    private static let allowed: Set<String> = ["\"whisper.cpp/whisper-cli\"", "\"SHEPETAL_WHISPER_CLI\"", "\"SHEPETAL_WHISPER_MODEL\""]

    static func offending(_ source: String) -> [String] {
        var hits: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") || code.contains("NSLog(") || code.contains("// not shown") { continue }
            let ns = code as NSString
            for m in literal.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range)
                if allowed.contains(s) { continue }
                let all = NSRange(location: 0, length: (s as NSString).length)
                if names.firstMatch(in: s, range: all) != nil || interpolated.firstMatch(in: s, range: all) != nil { hits.append(code) }
            }
        }
        return hits
    }

    func testTheScanCatchesAModelName() {
        XCTAssertEqual(Self.offending(#"engineStatus = "Model: Parakeet v3""#).count, 1)
        XCTAssertEqual(Self.offending(#"menu.addItem(item("Download (ggml-base.en, 60 MB)", #selector(x)))"#).count, 1)
        XCTAssertEqual(Self.offending(#"engineStatus = "Model: \(e.name)""#).count, 1)
        XCTAssertEqual(Self.offending(#"message = "Re-transcribed with \(done.model)""#).count, 1)
        XCTAssertEqual(Self.offending(#"others.map { ("With \($0.rawValue)", $0) }"#).count, 1)
        XCTAssertTrue(Self.offending(#"NSLog("shepetal: parakeet failed")"#).isEmpty)
        XCTAssertTrue(Self.offending(#"    // Parakeet v3 through FluidAudio"#).isEmpty)
        XCTAssertTrue(Self.offending(#"engineStatus = "On-device speech recognition (standard engine)""#).isEmpty)
    }

    func testNoModelNameInAppStrings() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Shepetal").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") && $0 != "E2E.swift" }
        XCTAssertTrue(files.contains("App.swift") && files.contains("Hub.swift"), "\(dir.path)")
        for f in files {
            let hits = Self.offending(try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8))
            XCTAssertTrue(hits.isEmpty, "\(f) shows a model name: \(hits)")
        }
    }
}
