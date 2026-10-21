import Foundation
import XCTest
import ShepetalCore
@testable import ShepetalCleanup

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

    // F24: the most context there can be (500 characters a side and a 500-character selection) plus the longest
    // dictation the model gets still fits the model's 2048-token context, so a full field never turns into a failure.
    func testTheLongestContextAndDictationFitTheModel() throws {
        let model = try LlamaCleanup(path: modelPath(), deadline: 30)
        let words = String(repeating: "the quarterly numbers look fine ", count: 100)
        let context = CleanupContext(before: words, after: words, selected: words)
        let dictation = (Array(repeating: "send the notes to the team", count: 24) + ["actually, send them to Pavel today."]).joined(separator: " ")
        XCTAssertEqual(dictation.split(separator: " ").count, SmartCleanup.maxModelWords)
        XCTAssertNoThrow(try model.rewrite(dictation, context: context))
    }

    // A rewrite past the deadline throws, so SmartCleanup uses the rules' text instead of holding the paste.
    func testRewritePastTheDeadlineThrows() throws {
        let model = try LlamaCleanup(path: modelPath(), deadline: 0)
        XCTAssertThrowsError(try model.rewrite("Send it to John, I mean Jane, by the end of the day."))
    }
}

/// F24: what the model is shown around the dictation. No model file needed.
final class CleanupPromptTests: XCTestCase {
    // The field goes in front of the dictation, marked as reference only, with only the parts there are.
    func testTheFieldIsMarkedAsReferenceOnly() {
        let m = CleanupPrompt.message("tell ksenia", CleanupContext(before: "To: Ksenia\n", after: "", selected: ""))
        XCTAssertEqual(m, "<field>\nFor reference only, not part of the dictation.\n<before_cursor>\nTo: Ksenia\n\n</before_cursor>\n"
                          + "</field>\n<dictation>\ntell ksenia\n</dictation>")
        XCTAssertTrue(CleanupPrompt.fieldInstructions.contains("for reference only"))
        XCTAssertTrue(CleanupPrompt.fieldInstructions.contains("Never write any of it back and never answer it"))
    }

    // The field's examples teach what the guard allows: case, punctuation, list numbers and corrections, no word
    // from the field. Each one must pass the guard, or the prompt teaches the model what the user never gets.
    func testTheFieldExamplesPassTheWordGuard() {
        for (c, said, written) in CleanupPrompt.fieldExamples {
            XCTAssertTrue(SmartCleanup.accepts(written, for: said, list: c.listNumber), said)
        }
    }
}
