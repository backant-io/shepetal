import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F45 Polish through PolishController with a fake model, a fake focus and selection, a temp history.sqlite and a
/// private pasteboard. Never the user's clipboard, focus, windows or defaults, and no key event is posted.
@MainActor
final class PolishFlowTests: XCTestCase {
    final class FakeModel: TextRewriter, CleanupModel, @unchecked Sendable {
        let name = "fake"
        var answer: () throws -> String
        private(set) var calls: [(instruction: String, text: String)] = []
        init(_ answer: @escaping () throws -> String) { self.answer = answer }
        func rewrite(instruction: String, text: String) throws -> String {
            calls.append((instruction, text))
            return try answer()
        }
        func rewrite(_ text: String) throws -> String { text }
    }

    struct Broken: Error {}

    private var root: URL!
    private var pasteboard: NSPasteboard!
    private var history: History!
    private var suite = ""
    private var defaults: UserDefaults!
    private var focused = true
    private var selected = "teh meeting is tomorow "
    private var selectionReads = 0
    private var secureInput: String?
    private var pastes = 0
    private var pasted: String?
    private var shown: [String] = []
    private var rings: [Indicator.Mode] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-polish-\(UUID().uuidString)")
        try AudioStore.makeOwnerOnlyDirectory(root)
        history = try History(path: root.appendingPathComponent("history.sqlite"))
        pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
        suite = "shepetal-polish-flow-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// `lands`: the target app reads the promised item when Cmd+V arrives, which is what makes the paste land.
    private func controller(_ model: PolishController.Model, lands: Bool = true) -> PolishController {
        let mac = PolishController.Mac(
            rememberFocus: { [unowned self] in { [unowned self] in focused } },
            selection: { [unowned self] in selectionReads += 1; return selected },
            secureInput: { [unowned self] in secureInput },
            app: { Task { AppContext(name: "TextEdit", bundleId: "com.apple.TextEdit") } },
            sendPaste: { [unowned self] event in
                guard event.type == .keyDown else { return }
                pastes += 1
                if lands { pasted = pasteboard.string(forType: .string) }
            })
        let c = PolishController(inserter: Inserter(pasteboard: pasteboard), history: history, model: { model }, mac: mac, defaults: defaults)
        c.retryDelay = .milliseconds(1)
        c.show = { [unowned self] text, _ in shown.append(text) }
        c.indicator = { [unowned self] in rings.append($0) }
        return c
    }

    private func assertUntouched(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(pastes, 0, "no Cmd+V", file: file, line: line)
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier", "the clipboard is left alone", file: file, line: line)
        XCTAssertEqual(try history.polishes(), [], file: file, line: line)
    }

    private func assertOnClipboard(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pastes, 0, "no Cmd+V", file: file, line: line)
        XCTAssertEqual(pasteboard.string(forType: .string), text, "the rewrite waits on the clipboard as plain text", file: file, line: line)
        XCTAssertEqual(rings.last, .error, file: file, line: line)
    }

    // M-POL-1 in code: the same window is focused when the rewrite is ready, so it replaces the selection.
    func testSameWindowPastesTheRewriteOverTheSelection() async throws {
        let model = FakeModel { "The meeting is tomorrow." }
        let message = await controller(.ready(model)).run()
        XCTAssertNil(message)
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(pasted, "The meeting is tomorrow. ", "the selection's trailing space is kept")
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier", "the user's clipboard comes back after the paste")
        XCTAssertEqual(model.calls.map(\.text), ["teh meeting is tomorow "])
        XCTAssertEqual(model.calls.map(\.instruction), [PolishPrompts.builtIn[0].instruction], "the default Polish prompt")
        XCTAssertEqual(rings, [.processing, .idle])
        let row = try XCTUnwrap(try history.polishes().first)
        XCTAssertEqual(row.outcome, .inserted)
        XCTAssertEqual([row.input, row.output, row.promptName, row.app, row.bundleId],
                       ["teh meeting is tomorow ", "The meeting is tomorrow. ", "Polish", "TextEdit", "com.apple.TextEdit"])
    }

    // Rule 8: the user switched windows while the model ran. Nothing is pasted, the rewrite is on the clipboard.
    func testFocusMovedWhileTheModelRanGoesToTheClipboard() async throws {
        let model = FakeModel { [unowned self] in focused = false; return "The meeting is tomorrow." }
        let message = await controller(.ready(model)).run()
        XCTAssertEqual(message, Polish.focusMoved)
        XCTAssertTrue(message?.hasSuffix("press ⌘V to paste it.") == true)
        assertOnClipboard("The meeting is tomorrow. ")
        XCTAssertEqual(selectionReads, 1, "the field that took focus is not read")
        XCTAssertEqual(shown, [Polish.focusMoved])
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.init("org.nspasteboard.TransientType")), "clipboard managers skip it")
        let row = try XCTUnwrap(try history.polishes().first)
        XCTAssertEqual([row.input, row.output], ["teh meeting is tomorow ", "The meeting is tomorrow. "])
        XCTAssertEqual(row.outcome, .pasteFailed)
    }

    // The user clicked elsewhere in the same window: a paste would go in at the new cursor, not over the text.
    func testSelectionChangedWhileTheModelRanGoesToTheClipboard() async throws {
        let model = FakeModel { [unowned self] in selected = ""; return "The meeting is tomorrow." }
        let message = await controller(.ready(model)).run()
        XCTAssertEqual(message, Polish.selectionChanged)
        assertOnClipboard("The meeting is tomorrow. ")
    }

    func testSecureInputGoesToTheClipboard() async throws {
        let model = FakeModel { [unowned self] in secureInput = "Terminal"; return "The meeting is tomorrow." }
        let message = await controller(.ready(model)).run()
        XCTAssertEqual(message, PasteGate.secureInput("Terminal"))
        assertOnClipboard("The meeting is tomorrow. ")
    }

    func testAPasteThatDoesNotLandLeavesTheRewriteOnTheClipboard() async throws {
        let message = await controller(.ready(FakeModel { "The meeting is tomorrow." }), lands: false).run()
        XCTAssertEqual(message, PasteGate.notLanded)
        XCTAssertEqual(pasteboard.string(forType: .string), "The meeting is tomorrow. ")
        XCTAssertEqual(try history.polishes().first?.outcome, .pasteFailed)
    }

    func testNoSelectionShowsTheHintAndNeverCallsTheModel() async throws {
        for nothing in ["", " \n "] {
            selected = nothing
            selectionReads = 0
            let model = FakeModel { "Something." }
            let message = await controller(.ready(model)).run()
            XCTAssertEqual(message, "Select text first")
            XCTAssertEqual(model.calls.count, 0)
            XCTAssertFalse(rings.contains(.processing))
            try assertUntouched()
        }
        XCTAssertEqual(selectionReads, 1, "a selection of white space is not read again")
        selected = ""
        selectionReads = 0
        _ = await controller(.ready(FakeModel { "" })).run()
        XCTAssertEqual(selectionReads, 2, "an empty one is read once more: an Electron app builds its AX tree when asked")
    }

    func testATooLongSelectionShowsTheHint() async throws {
        selected = String(repeating: "word ", count: Polish.maxWords + 1)
        let model = FakeModel { "Something." }
        let message = await controller(.ready(model)).run()
        XCTAssertEqual(message, Polish.tooLong)
        XCTAssertEqual(model.calls.count, 0)
        try assertUntouched()
    }

    func testWithoutTheModelTheHintSaysWhatToDo() async throws {
        let m1 = await controller(.notDownloaded).run()
        XCTAssertEqual(m1, Polish.needsModel)
        XCTAssertTrue(Polish.needsModel.contains("Download cleanup model"), "the 🤫 menu item's wording")
        let m2 = await controller(.downloading).run()
        XCTAssertEqual(m2, Polish.downloading)
        let m3 = await controller(.loading).run()
        XCTAssertEqual(m3, Polish.loading)
        let m4 = await controller(.unavailable).run()
        XCTAssertEqual(m4, Polish.notOnThisMac)
        let m5 = await controller(.couldNotLoad).run()
        XCTAssertEqual(m5, Polish.failed)
        try assertUntouched()
        for message in shown { XCTAssertFalse(message.contains("Qwen") || message.contains("llama"), "no model name") }
    }

    // A model error, an empty answer or a runaway leaves the selection, the clipboard and history as they were.
    func testABadAnswerLeavesTheSelectionUntouched() async throws {
        let answers: [() throws -> String] = [{ throw Broken() }, { "" }, { "   " }, { String(repeating: "Yes. ", count: 100) }]
        for answer in answers {
            let message = await controller(.ready(FakeModel(answer))).run()
            XCTAssertEqual(message, Polish.failed)
            XCTAssertEqual(rings.last, .error)
            try assertUntouched()
        }
    }

    func testAnUnchangedAnswerPastesNothing() async throws {
        selected = "The meeting is tomorrow."
        let message = await controller(.ready(FakeModel { "The meeting is tomorrow." })).run()
        XCTAssertEqual(message, Polish.unchanged)
        try assertUntouched()
    }

    // The 🤫 menu lists the saved prompts with the active one checked; a click picks the prompt the hotkey uses.
    func testTheMenuPicksThePromptTheHotkeyUses() async throws {
        let model = FakeModel { "Short." }
        let c = controller(.ready(model))
        let item = try XCTUnwrap(c.menuItem(chord: Shortcuts.defaults[.polish] ?? []))
        XCTAssertEqual(item.title, "Polish prompt (⌃ ⌘ P)")
        let items = try XCTUnwrap(item.submenu?.items)
        XCTAssertEqual(items.map(\.title), PolishPrompts.builtIn.map(\.name))
        XCTAssertEqual(items.map { $0.state }, [NSControl.StateValue.on, .off, .off])
        XCTAssertTrue(items.allSatisfy { $0.isEnabled && $0.action != nil }, "never a grey item")
        items[1].click()
        XCTAssertEqual(PolishPrompts.active(defaults).name, "Shorter")
        XCTAssertEqual(c.menuItem(chord: [])?.submenu?.items.map { $0.state }, [NSControl.StateValue.off, .on, .off])
        _ = await c.run()
        XCTAssertEqual(model.calls.first?.instruction, PolishPrompts.builtIn[1].instruction)
        XCTAssertEqual(try history.polishes().first?.promptName, "Shorter")
        XCTAssertNil(controller(.unavailable).menuItem(chord: []), "hidden on a Mac without the cleanup model")
        XCTAssertNotNil(controller(.notDownloaded).menuItem(chord: []), "the prompts can be picked before the download")
    }

    func testOnePolishAtATimeAndNoneWhileDictating() async throws {
        let c = controller(.ready(FakeModel { "The meeting is tomorrow." }))
        c.start(dictating: true)
        XCTAssertNil(c.running)
        XCTAssertEqual(shown, [Polish.busy])
        c.start(dictating: false)
        let first = try XCTUnwrap(c.running)
        c.start(dictating: false)
        XCTAssertEqual(shown, [Polish.busy, Polish.running])
        await first.value
        XCTAssertNil(c.running)
        XCTAssertEqual(pastes, 1, "only the first one ran")
    }

    func testTheModelStateFollowsThePipelinesCleanupModel() throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        guard currentCleanupModel() != nil else { throw XCTSkip("no cleanup model for this Mac") }
        guard case .notDownloaded = PolishController.model(pipeline) else { return XCTFail("nothing downloaded") }
        pipeline.cleanup = FakeModel { "" }
        guard case .ready = PolishController.model(pipeline) else { return XCTFail("the loaded cleanup model polishes") }
    }
}

private extension NSMenuItem {
    /// What a click on the item does.
    func click() { _ = (target as? NSObject)?.perform(action, with: self) }
}
