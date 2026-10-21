import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F41 through the real Pipeline: a temp data dir, a private pasteboard and a stub translator, never the user's
/// clipboard, settings, data or Apple's translation.
@MainActor
final class TranslationPipelineTests: XCTestCase {
    var root: URL!
    var pasteboard: NSPasteboard!
    let german = "Hallo, wie geht es dir heute?"
    let textEdit = AppContext(name: "TextEdit", bundleId: "com.apple.TextEdit")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-test-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    func pipeline(_ translator: Translator?, on: Bool = true) throws -> Pipeline {
        let p = try Pipeline(root: root, pasteboard: pasteboard)
        p.useFieldContext = { false }
        p.pressEnterCommand = { false }
        p.translate = TranslateStep(isOn: { on }, languages: { [] }, translator: translator)
        return p
    }

    /// The paste reads the clipboard, so it lands; returns what was pasted.
    func dictate(_ p: Pipeline) async -> (Pipeline.Run, String?) {
        var pasted: String?
        let run = await p.process(tone(db: -30), engine: FakeEngine(german), app: textEdit, context: { ("", "", "") },
                                  sendPaste: { [pasteboard] e in if e.type == .keyDown { pasted = pasteboard!.string(forType: .string) } })
        return (run, pasted)
    }

    // On: the English is pasted, History keeps what was said as the raw text and the English as the text.
    func testTheTranslationIsPastedAndHistoryKeepsBoth() async throws {
        let stub = TranslationTests.StubTranslator()
        let p = try pipeline(stub)
        let (run, pasted) = await dictate(p)
        XCTAssertEqual(pasted, "Hello, how are you today?")
        XCTAssertNil(run.translationHint)
        XCTAssertEqual(run.entry.outcome, .inserted)
        let row = try XCTUnwrap(try p.history.recent().first { $0.id == run.entry.id })
        XCTAssertEqual(row.rawText, german, "what was said")
        XCTAssertEqual(row.text, "Hello, how are you today?", "what landed")
        XCTAssertEqual(stub.calls.map(\.source), ["de"])
    }

    // Off (the default): the German lands and no translator is asked.
    func testOffPastesWhatWasSaid() async throws {
        let stub = TranslationTests.StubTranslator()
        let (run, pasted) = await dictate(try pipeline(stub, on: false))
        XCTAssertEqual(pasted, german)
        XCTAssertEqual(run.entry.text, german)
        XCTAssertNil(run.translationHint)
        XCTAssertTrue(stub.calls.isEmpty)
    }

    // A failure still pastes, untranslated, and the run carries the hint the app shows next to 🤫.
    func testAFailurePastesTheOriginalWithTheHint() async throws {
        let stub = TranslationTests.StubTranslator()
        stub.result = .failure(.notDownloaded)
        let (run, pasted) = await dictate(try pipeline(stub))
        XCTAssertEqual(pasted, german)
        XCTAssertEqual(run.entry.outcome, .inserted)
        XCTAssertEqual(run.entry.text, german)
        XCTAssertEqual(run.translationHint, Translate.hint(.notDownloaded, "de"))
    }

    // History's re-transcribe goes through the same step: the row's text becomes the English.
    func testRetranscribeTranslatesToo() async throws {
        let off = try pipeline(nil, on: false)
        let (run, _) = await dictate(off)
        let row = try XCTUnwrap(try off.history.recent().first { $0.id == run.entry.id })
        XCTAssertEqual(row.text, german)
        let stub = TranslationTests.StubTranslator()
        off.translate = TranslateStep(isOn: { true }, languages: { [] }, translator: stub)
        let again = try await off.retranscribe(row, with: FakeEngine(german))
        XCTAssertEqual(again.rawText, german)
        XCTAssertEqual(again.text, "Hello, how are you today?")
        XCTAssertEqual(try off.history.recent().first { $0.id == run.entry.id }?.text, "Hello, how are you today?")
    }

    // The app shows the hint next to 🤫 after a dictation (the indicator cannot be checked here: pinned by source).
    func testTheAppShowsTheHint() throws {
        let app = try AppSource.code("App.swift")
        XCTAssertTrue(app.contains("if !Task.isCancelled, run.error == nil, let hint = run.translationHint { indicator.show(hint, seconds: 4) }"))
    }
}
