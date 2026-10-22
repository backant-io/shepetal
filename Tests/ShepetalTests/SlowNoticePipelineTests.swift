import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F18 through the real Pipeline: someone waiting on a slow transcription hears once that it is still working.
/// The notice must not nag: never on a fast run, a silent one, after Esc, or with the threshold at 0.
/// A temp data dir and a private pasteboard, never the user's.
@MainActor
final class SlowNoticePipelineTests: XCTestCase {
    /// Takes `delay` seconds and stops early when its task is cancelled (Esc). With `ignoresEsc` it finishes the
    /// work anyway, like an engine that never checks for cancellation.
    final class SlowEngine: SpeechEngine {
        let name = "slow"
        let delay: TimeInterval, ignoresEsc: Bool
        init(_ delay: TimeInterval, ignoresEsc: Bool = false) { self.delay = delay; self.ignoresEsc = ignoresEsc }
        func transcribe(_ samples: [Float], wav: URL) async throws -> String {
            let ns = UInt64(delay * 1e9)
            if ignoresEsc { try await Task.detached { try await Task.sleep(nanoseconds: ns) }.value } else { try await Task.sleep(nanoseconds: ns) }
            return "hello there"
        }
    }

    var root: URL!
    var pasteboard: NSPasteboard!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-slow-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    /// How often `slow` ran, counted until 0.3 s past both the threshold and the end of `process`, where a late
    /// notice would land. With `holdPaste`, the paste starts only once the threshold has passed (`willPaste` blocks
    /// the main actor until then, so a notice still armed fires as soon as the paste waits).
    func notices(_ samples: [Float], _ engine: SpeechEngine, after: TimeInterval, cancelAt: TimeInterval? = nil,
                 holdPaste: Bool = false) async throws -> (count: Int, outcome: Outcome, readyMs: Double) {
        let p = try Pipeline(root: root, pasteboard: pasteboard)
        let start = Date()
        p.slowAfter = { after }
        let count = SlowCount()
        let willPaste = holdPaste ? { Thread.sleep(until: start.addingTimeInterval(after + 0.3)) } : {}
        let task = Task {
            await p.process(samples, engine: engine, context: { ("", "", "") }, willPaste: willPaste, sendPaste: { _ in },
                            slow: { count.value += 1 })
        }
        if let cancelAt {
            try await Task.sleep(nanoseconds: UInt64(cancelAt * 1e9))
            task.cancel()
        }
        let run = await task.value
        let elapsed = Date().timeIntervalSince(start)
        try await Task.sleep(nanoseconds: UInt64((max(after, elapsed) + 0.3 - elapsed) * 1e9))
        return (count.value, run.entry.outcome, run.readyMs)
    }

    func testASlowTranscriptionGetsTheNoticeOnce() async throws {
        let r = try await notices(tone(db: -30), SlowEngine(0.4), after: 0.05)
        XCTAssertEqual(r.count, 1)
    }

    // Voice isolation runs before speech-to-text and takes a second or more here, so "fast" is a threshold the
    // run stays under; the wait past it shows the notice was stopped, not just late.
    func testAFastOneNever() async throws {
        let r = try await notices(tone(db: -30), FakeEngine("hello there"), after: 5)
        XCTAssertLessThan(r.readyMs, 5_000, "the run must beat the threshold for this test to mean anything")
        XCTAssertEqual(r.count, 0)
    }

    // The text is ready before the threshold, but the paste runs past it (a slow app, or the 1 s wait for one that
    // ignores Cmd+V): the notice must not appear while the text is already going in.
    func testNeverOnceThePasteStarts() async throws {
        let r = try await notices(tone(db: -30), FakeEngine("hello there"), after: 5, holdPaste: true)
        XCTAssertLessThan(r.readyMs, 5_000, "the text must be ready before the threshold for this test to mean anything")
        XCTAssertEqual(r.count, 0)
    }

    func testSilenceNever() async throws {
        let r = try await notices([Float](repeating: 0, count: 16_000), SlowEngine(0.4), after: 0.05)
        XCTAssertEqual(r.outcome, .noSpeech)
        XCTAssertEqual(r.count, 0, "silence never reaches the model")
    }

    // Esc 0.05 s in, with a 0.2 s threshold: an engine that stops at once, and one that keeps working past it.
    func testEscWhileTranscribingNever() async throws {
        for ignoresEsc in [false, true] {
            let r = try await notices(tone(db: -30), SlowEngine(0.6, ignoresEsc: ignoresEsc), after: 0.2, cancelAt: 0.05)
            XCTAssertEqual(r.outcome, .cancelled, "ignoresEsc: \(ignoresEsc)")
            XCTAssertEqual(r.count, 0, "ignoresEsc: \(ignoresEsc)")
        }
    }

    func testZeroIsOff() async throws {
        let r = try await notices(tone(db: -30), SlowEngine(0.3), after: 0)
        XCTAssertEqual(r.count, 0)
    }
}

@MainActor
final class SlowCount { var value = 0 }

/// F18, F118: the views and the transcription cannot run in a test, so this pins by source that they are wired.
final class MiscWiringTests: XCTestCase {
    func testTranscribeShowsAndClearsTheSlowNotice() throws {
        let rest = try XCTUnwrap(try AppSource.code("App.swift").components(separatedBy: "private func transcribe(").dropFirst().first)
        let transcribe = try XCTUnwrap(rest.components(separatedBy: "\n    }\n").first, "transcribe(_:)'s body only")
        XCTAssertTrue(transcribe.contains("slow: { [weak self] in self?.indicator.show(SlowNotice.hint"), "F18's notice is never shown")
        XCTAssertTrue(transcribe.contains("indicator.labelText == SlowNotice.hint"), "the notice outlives the dictation")
    }

    func testHomeTabHasShareStats() throws {
        let home = try AppSource.body(of: "private struct HomeTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(home.contains("ShareStatsSection(history: model.pipeline.history)"), "F118 is unreachable")
    }
}
