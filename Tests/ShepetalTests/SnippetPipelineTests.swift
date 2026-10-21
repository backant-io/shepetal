import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F40 through the pipeline: snippets.toml in the data dir is read on every dictation and on re-transcribe. A
/// dictation that is only a trigger goes in exactly as stored, rich where the field takes it: the fit to the cursor
/// would lowercase it mid-sentence and trim its last line break, and a plain-only paste would drop its bold.
/// A temp data dir and a private pasteboard: never the user's snippets or clipboard.
@MainActor
final class SnippetPipelineTests: XCTestCase {
    var root: URL!
    var pasteboard: NSPasteboard!
    let speech = tone(db: -30)
    let toml = #""my signature" = "**Ada Lovelace**\n[backant.io](https://backant.io)\n"\#n"my address" = "221B Baker Street""#

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

    /// A pipeline on `root` with `toml` in its snippets.toml, and dictation into "Thanks," (mid-sentence).
    func dictate(_ said: String, reading type: NSPasteboard.PasteboardType) async throws -> (Pipeline.Run, String?, [NSPasteboard.PasteboardType]) {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        XCTAssertEqual(pipeline.snippets, root.appendingPathComponent("snippets.toml"))
        try toml.write(to: pipeline.snippets, atomically: true, encoding: .utf8)
        var got: String?, offered: [NSPasteboard.PasteboardType] = []
        let run = await pipeline.process(speech, engine: FakeEngine(said), context: { ("Thanks,", "", "") }, sendPaste: { [pasteboard] e in
            guard e.type == .keyDown else { return }
            offered = pasteboard!.pasteboardItems?.first?.types ?? []
            got = pasteboard!.string(forType: type)
        })
        return (run, got, offered)
    }

    func testWholeDictationSnippetIsPastedVerbatimAndRich() async throws {
        let (run, html, offered) = try await dictate("Um, my signature.", reading: .html)
        XCTAssertEqual(run.paste?.landed, true, "Mail took the HTML")
        XCTAssertEqual(run.inserted, "Ada Lovelace\nbackant.io\n", "no space or lowercase from the cursor, the last line break kept")
        XCTAssertEqual(run.entry.text, "Ada Lovelace\nbackant.io\n", "history keeps the plain text")
        XCTAssertEqual(html, Snippets.render("**Ada Lovelace**\n[backant.io](https://backant.io)\n").html)
        XCTAssertEqual(Array(offered.prefix(2)), [.html, .string])
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier", "the clipboard comes back")
    }

    func testTerminalGetsTheSnippetsPlainText() async throws {
        let (run, plain, _) = try await dictate("my signature", reading: .string)
        XCTAssertEqual(run.paste?.landed, true)
        XCTAssertEqual(plain, "Ada Lovelace\nbackant.io\n")
    }

    func testInlineTriggerIsFittedLikeAnyDictation() async throws {
        let (run, plain, offered) = try await dictate("Send it to my address.", reading: .string)
        XCTAssertNil(run.snippet)
        XCTAssertEqual(plain, InsertionRules.fit("Send it to 221B Baker Street.", before: "Thanks,", after: ""))
        XCTAssertFalse(offered.contains(.html), "a sentence is plain text")
    }

    /// Rule 8: focus moved, so nothing is pasted, and the snippet waits on the clipboard exactly as stored.
    func testSnippetLeftOnTheClipboardIsExactlyAsStored() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        try toml.write(to: pipeline.snippets, atomically: true, encoding: .utf8)
        let run = await pipeline.process(speech, engine: FakeEngine("my signature"), context: { ("", "", "") },
                                         focusKept: { false }, sendPaste: { _ in XCTFail("nothing may be pasted") })
        XCTAssertEqual(run.entry.outcome, .pasteFailed)
        XCTAssertEqual(pasteboard.string(forType: .string), "Ada Lovelace\nbackant.io\n")
    }

    /// Re-transcribe reads the same file, so a row re-run with another engine gets the snippet too.
    func testRetranscribeReadsThePipelinesSnippets() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let run = await pipeline.process(speech, engine: FakeEngine("Hello."), context: { ("", "", "") }, sendPaste: { _ in })
        try toml.write(to: pipeline.snippets, atomically: true, encoding: .utf8)
        let row = try XCTUnwrap(try pipeline.history.recent().first { $0.id == run.entry.id })
        let again = try await pipeline.retranscribe(row, with: FakeEngine("My address!"))
        XCTAssertEqual(again.text, "221B Baker Street")
        let suite = "shepetal-test-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        pipeline.appFormat = AppFormat(defaults)
        pipeline.appFormat.defaultMode = .raw
        let raw = await pipeline.finishText("My signature.")
        XCTAssertNotNil(raw.snippet, "Raw keeps the whole-dictation snippet, so it is pasted rich and not fitted")
        XCTAssertEqual(raw.text, "Ada Lovelace\nbackant.io\n", "Raw gets it exactly as stored, like Formatted")
    }

    func testSettingsHasSnippetsNextToDictionary() throws {
        let settings = try AppSource.body(of: "private struct SettingsTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(settings.contains("""
                        Button("Dictionary…", action: model.openDictionary)
                        Button("Snippets…") { SnippetsFile.open(model.pipeline.snippets) }
            """), "Snippets… opens the pipeline's own snippets.toml, right below Dictionary…")
    }
}
