import Foundation
import XCTest
import ShepetalCleanup

/// The real llama.cpp model. Set SHEPETAL_CLEANUP_MODEL to a GGUF from docs/models.md (Cleanup) to run these;
/// without it they are skipped, and the skip shows in the test output.
final class LlamaCleanupTests: XCTestCase {
    private func modelPath() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["SHEPETAL_CLEANUP_MODEL"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("SHEPETAL_CLEANUP_MODEL is not set to a cleanup model file")
        }
        return path
    }

    // Dictation and History's re-transcribe can call the same model at once. Each call must still get the
    // answer it gets alone: the model serializes calls on its one context.
    func testConcurrentRewritesGetTheSameTextAsOneAtATime() throws {
        let model = try LlamaCleanup(path: modelPath(), deadline: 30)
        let texts = ["Send it to John, I mean Jane, by the end of the day.",
                     "Things to pack. First, passport. Second, charger. Third, headphones."]
        let alone = try texts.map { try model.rewrite($0) }
        let results = NSMutableArray(array: Array(repeating: "", count: 8))
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            let out = (try? model.rewrite(texts[i % 2])) ?? "error"
            lock.withLock { results[i] = out }
        }
        for i in 0..<8 { XCTAssertEqual(results[i] as? String, alone[i % 2], "call \(i)") }
    }

    // A rewrite past the deadline throws, so SmartCleanup uses the rules' text instead of holding the paste.
    func testRewritePastTheDeadlineThrows() throws {
        let model = try LlamaCleanup(path: modelPath(), deadline: 0)
        XCTAssertThrowsError(try model.rewrite("Send it to John, I mean Jane, by the end of the day."))
    }
}
