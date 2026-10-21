import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F24: with Settings' "Use the text around the cursor to clean up dictation" on, the field is read once, before
/// cleanup, and the cleanup model gets it cut down (on by default); switched off, the model gets nothing and the field
/// is read after cleanup, as before. Rule 8 is checked before the read, Esc still counts until the paste starts, and the
/// field's text never reaches History. A temp data dir and a private pasteboard: never the user's clipboard or data.
final class FieldContextPipelineTests: XCTestCase {
    var root: URL!
    var pasteboard: NSPasteboard!
    let speech = tone(db: -30)
    let said = "tell ksenia the draft is ready"
    let ksenia: FocusedText.Context = ("To: Ksenia\n\n", "", "")

    /// Records what it was given and when, next to the field reads and the paste.
    final class ContextModel: CleanupModel, @unchecked Sendable {
        let name = "context"
        var contexts: [CleanupContext] = []
        var log: [String] = []
        func rewrite(_ text: String) throws -> String { try rewrite(text, context: .none) }
        func rewrite(_ text: String, context: CleanupContext) throws -> String {
            contexts.append(context)
            log.append("cleanup")
            return context.before.contains("Ksenia") ? "Tell Ksenia the draft is ready." : "Tell ksenia the draft is ready."
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-test-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func dictate(on: Bool, field: FocusedText.Context, focusKept: @escaping () -> Bool? = { nil },
                         secureInput: @escaping () -> String? = { nil }) async throws -> (Pipeline, ContextModel, Pipeline.Run) {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.useFieldContext = { on }
        let model = ContextModel()
        pipeline.cleanup = model
        let run = await pipeline.process(speech, engine: FakeEngine(said), context: { model.log.append("read"); return field },
                                         willPaste: { model.log.append("paste") }, focusKept: focusKept, secureInput: secureInput,
                                         sendPaste: { [pasteboard] e in if e.type == .keyDown { _ = pasteboard!.string(forType: .string) } })
        return (pipeline, model, run)
    }

    // On by default (Pavel, 2026-10-21). Switched off: the model gets nothing from the field, and the field is read
    // after cleanup, as before F24.
    @MainActor
    func testOnByDefaultAndSwitchedOffTheModelGetsNothing() async throws {
        XCTAssertTrue(try Pipeline(root: root, pasteboard: pasteboard).useFieldContext(), "on unless the user switches it off")
        let (_, model, run) = try await dictate(on: false, field: ksenia)
        XCTAssertEqual(model.contexts, [.none])
        XCTAssertEqual(model.log, ["cleanup", "paste", "read"])
        XCTAssertEqual(run.entry.text, "Tell ksenia the draft is ready.")
    }

    // On: one read, before cleanup; the model gets that field cut down, and the paste fits to the same read.
    // The paste starts only after cleanup, so Esc still cancels while the model runs.
    @MainActor
    func testOnTheFieldIsReadOnceBeforeCleanup() async throws {
        let long = String(repeating: "word ", count: 300) + "To: Ksenia\n\n"
        let (_, model, run) = try await dictate(on: true, field: (long, "", ""))
        XCTAssertEqual(model.log, ["read", "cleanup", "paste"], "read once, and the paste starts after cleanup")
        XCTAssertEqual(model.contexts, [CleanupContext(before: long, after: "", selected: "")])
        XCTAssertLessThanOrEqual(model.contexts[0].before.count, CleanupContext.limit, "the model gets 500 characters, not the field")
        XCTAssertEqual(run.entry.text, "Tell Ksenia the draft is ready.")
        XCTAssertEqual(run.inserted, InsertionRules.fit("Tell Ksenia the draft is ready.", before: long, after: ""))
        XCTAssertEqual(run.entry.outcome, .inserted)
    }

    // A field that cannot be read gives an empty context, and the dictation goes in as usual.
    @MainActor
    func testAnUnreadableFieldGivesAnEmptyContext() async throws {
        let (_, model, run) = try await dictate(on: true, field: ("", "", ""))
        XCTAssertEqual(model.contexts, [.none])
        XCTAssertEqual(model.log, ["read", "cleanup", "paste"])
        XCTAssertEqual(run.entry.outcome, .inserted)
    }

    // Rule 8 before the read: when focus moved or secure input is on, the field is not read, the model gets
    // nothing, and the text waits on the clipboard as dictated.
    @MainActor
    func testRule8IsCheckedBeforeTheFieldIsRead() async throws {
        for (kept, secure, message) in [(false, nil as String?, PasteGate.focusMoved), (true, "Safari", PasteGate.secureInput("Safari"))] {
            let (_, model, run) = try await dictate(on: true, field: ksenia, focusKept: { kept }, secureInput: { secure })
            XCTAssertFalse(model.log.contains("read"), message)
            XCTAssertEqual(model.contexts, [.none], message)
            XCTAssertEqual(run.error, message)
            XCTAssertEqual(run.entry.outcome, .pasteFailed)
            XCTAssertEqual(pasteboard.string(forType: .string), "Tell ksenia the draft is ready.", message)
        }
    }

    // The field's text is never stored: History keeps the dictation only, and re-transcribing sends no context.
    @MainActor
    func testTheFieldNeverReachesHistory() async throws {
        let secret: FocusedText.Context = ("Private note 7f3a for Ksenia\n", "after 7f3a", "selected 7f3a")
        let (pipeline, model, run) = try await dictate(on: true, field: secret)
        let row = try XCTUnwrap(try pipeline.history.recent().first { $0.id == run.entry.id })
        XCTAssertFalse("\(row)".contains("7f3a"), "no part of the field is in the history row")
        XCTAssertEqual(row.rawText, said)
        _ = try await pipeline.retranscribe(row, with: FakeEngine(said))
        XCTAssertEqual(model.contexts.last, CleanupContext.none, "re-transcription has no field")
        XCTAssertFalse(try pipeline.history.recent().contains { "\($0)".contains("7f3a") })
    }
}
