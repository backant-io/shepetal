import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F33 and F48 through the real Pipeline: a temp data dir, a private pasteboard and a private UserDefaults
/// suite, never the user's clipboard, settings or data.
final class AppFormatPipelineTests: XCTestCase {
    var root: URL!
    var pasteboard: NSPasteboard!
    var defaults: UserDefaults!
    var suite: String!
    let said = "Um, on the fifth of March."
    let terminal = AppContext(name: "Terminal", bundleId: "com.apple.Terminal")
    let textEdit = AppContext(name: "TextEdit", bundleId: "com.apple.TextEdit")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-test-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        suite = "shepetal-appformat-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func pipeline() throws -> Pipeline {
        let p = try Pipeline(root: root, pasteboard: pasteboard)
        p.appFormat = AppFormat(defaults)
        p.styleDefaults = defaults  // no style picked: the checks below see the format alone
        p.appFormat.set(.raw, for: terminal.bundleId)
        return p
    }

    /// The paste reads the clipboard, so it lands; returns what was pasted.
    @MainActor
    func dictate(_ p: Pipeline, into app: AppContext) async -> (Pipeline.Run, String?) {
        var pasted: String?
        let run = await p.process(tone(db: -30), engine: FakeEngine(said), app: app, context: { ("", "", "") },
                                  sendPaste: { [pasteboard] e in if e.type == .keyDown { pasted = pasteboard!.string(forType: .string) } })
        return (run, pasted)
    }

    // Terminal is Raw, TextEdit is on the default: the same words keep "Um" and the spoken date in Terminal
    // and are cleaned, with the date as numbers, in TextEdit.
    @MainActor
    func testARawAppKeepsFillersAndSpokenDatesAndAFormattedAppIsCleaned() async throws {
        let p = try pipeline()
        let (raw, rawPaste) = await dictate(p, into: terminal)
        XCTAssertEqual(rawPaste, said)
        XCTAssertEqual(raw.entry.text, said)
        let (cleaned, cleanedPaste) = await dictate(p, into: textEdit)
        XCTAssertEqual(cleanedPaste, "On 05.03.")
        XCTAssertEqual(cleaned.entry.text, "On 05.03.")
    }

    // Re-transcribe in History uses the row's app, and the app's choice as it is now.
    @MainActor
    func testRetranscribeFollowsTheRowsApp() async throws {
        let p = try pipeline()
        let (run, _) = await dictate(p, into: terminal)
        let row = try XCTUnwrap(try p.history.recent().first { $0.id == run.entry.id })
        let again = try await p.retranscribe(row, with: FakeEngine(said))
        XCTAssertEqual(again.text, said, "Terminal is still Raw")
        p.appFormat.set(.formatted, for: terminal.bundleId)
        let formatted = try await p.retranscribe(row, with: FakeEngine(said))
        XCTAssertEqual(formatted.text, "On 05.03.")
    }

    // F48: after Show raw, copy last puts the raw words on the clipboard; after Show cleaned, the cleaned text.
    @MainActor
    func testCopyLastFollowsShowRaw() async throws {
        let p = try pipeline()
        let (run, _) = await dictate(p, into: textEdit)
        try p.history.setReverted(run.entry.id, true)
        XCTAssertEqual(p.copyLast(), said)
        XCTAssertEqual(pasteboard.string(forType: .string), said)
        try p.history.setReverted(run.entry.id, false)
        XCTAssertEqual(p.copyLast(), "On 05.03.")
    }

    // F48: the 🤫 menu's Recent copies what History shows.
    func testRecentCopiesTheShownText() {
        let row = HistoryEntry(id: "a", createdAt: Date(), outcome: .inserted, audioPath: "", durationMs: 0,
                               rawText: "um, on the fifth of march", text: "On 05.03.", reverted: true)
        XCTAssertEqual(MenuModel.recent([row]).first?.action, .copy("um, on the fifth of march"))
        XCTAssertEqual(MenuModel.recent([row]).first?.title, "um, on the fifth of march")
    }

    // The window cannot be rendered in a test, so these pin by source what History and Settings show.
    func testHistoryRowShowsAndCopiesTheShownTextAndHasTheSwitch() throws {
        let hub = try AppSource.code("Hub.swift")
        let tab = try AppSource.body(of: "private struct HistoryTab: View {", in: hub)
        XCTAssertTrue(tab.contains("Button(e.reverted ? \"Show cleaned\" : \"Show raw\") { model.setReverted(e, !e.reverted) }"))
        XCTAssertTrue(tab.contains("Text(e.shownText.isEmpty ? \"Nothing transcribed\" : e.shownText)"))
        XCTAssertTrue(hub.contains("pipeline.copy(e.shownText)"), "Copy follows the shown text")
        XCTAssertTrue(hub.contains("try pipeline.history.setReverted(e.id, reverted)"))
        XCTAssertTrue(hub.contains("let finished = await finishText(e.rawText, bundleId: e.bundleId, url: e.url)"), "re-transcribe uses the row's app")
    }

    func testSettingsShowsFormattingPerApp() throws {
        let settings = try AppSource.body(of: "private struct SettingsTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(settings.contains("AppFormatSection(history: model.pipeline.history)"))
    }
}
