import SQLite3
import XCTest
@testable import ShepetalCore

/// F45 Polish, the pure part: the saved prompts in UserDefaults, the check on the model's answer, the shortcut, and
/// the polish rows in history.sqlite. Defaults live in a throwaway suite and the database in a temp file.
final class PolishTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var dbURL: URL!

    override func setUpWithError() throws {
        suite = "shepetal-polish-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-polish-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: saved prompts

    func testTheBuiltInPolishPromptIsThereUntilPromptsAreSaved() {
        XCTAssertEqual(PolishPrompts.load(defaults), PolishPrompts.builtIn)
        XCTAssertEqual(PolishPrompts.builtIn.first?.name, "Polish", "the default prompt is Polish")
        XCTAssertEqual(PolishPrompts.active(defaults).name, "Polish")
        for p in PolishPrompts.builtIn {
            XCTAssertFalse(p.instruction.isEmpty)
            XCTAssertFalse(p.instruction.lowercased().contains("flow"), "our own wording")
        }
    }

    func testSavedPromptsRoundTrip() {
        let mine = [PolishPrompt(name: "Polish", instruction: "Fix typos only."),
                    PolishPrompt(name: "Pirate", instruction: "Rewrite it as a pirate would say it.")]
        PolishPrompts.save(mine, defaults)
        XCTAssertEqual(PolishPrompts.load(defaults), mine)
        XCTAssertEqual(PolishPrompts.load(UserDefaults(suiteName: suite)!), mine, "read back from the stored data")
    }

    func testTheActivePromptIsThePickedOneElseTheFirst() {
        XCTAssertEqual(PolishPrompts.active(defaults), PolishPrompts.builtIn[0])
        PolishPrompts.setActive("Shorter", defaults)
        XCTAssertEqual(PolishPrompts.active(defaults).name, "Shorter")
        PolishPrompts.save([PolishPrompt(name: "Mine", instruction: "Do it.")], defaults)
        XCTAssertEqual(PolishPrompts.active(defaults).name, "Mine", "the picked prompt was removed: the first one")
    }

    func testUnusablePromptsAreDroppedAndNothingUsableGivesTheBuiltIns() {
        PolishPrompts.save([PolishPrompt(name: "  ", instruction: "No name."),
                            PolishPrompt(name: "Empty", instruction: "\n"),
                            PolishPrompt(name: " Kept ", instruction: " Keep it. "),
                            PolishPrompt(name: "Kept", instruction: "A second Kept.")], defaults)
        XCTAssertEqual(PolishPrompts.load(defaults), [PolishPrompt(name: "Kept", instruction: "Keep it.")])
        PolishPrompts.save([PolishPrompt(name: "", instruction: "")], defaults)
        XCTAssertEqual(PolishPrompts.load(defaults), PolishPrompts.builtIn)
        defaults.set(Data("not json".utf8), forKey: PolishPrompts.listKey)
        XCTAssertEqual(PolishPrompts.load(defaults), PolishPrompts.builtIn)
    }

    // MARK: the model's answer

    func testEmptyAndRunawayAnswersAreRejected() {
        let input = "teh meeting is tomorow"
        XCTAssertNil(Polish.accept("", for: input))
        XCTAssertNil(Polish.accept("  \n ", for: input))
        XCTAssertNil(Polish.accept("<text></text>", for: input))
        XCTAssertNil(Polish.accept("“ ... ”", for: input), "no letter or digit")
        XCTAssertNil(Polish.accept(String(repeating: "The meeting is tomorrow. ", count: 12), for: input), "runaway")
        XCTAssertEqual(Polish.accept("The meeting is tomorrow.", for: input), "The meeting is tomorrow.")
        let long = String(repeating: "x", count: input.count * 2 + 200)
        XCTAssertEqual(Polish.accept(long, for: input), long, "twice the text plus 200 is still fine")
        XCTAssertNil(Polish.accept(long + "x", for: input))
    }

    func testTheAnswerKeepsTheSelectionsOuterWhiteSpaceAndLosesQuotesAndTags() {
        XCTAssertEqual(Polish.accept("The meeting is tomorrow.", for: "teh meeting is tomorow "), "The meeting is tomorrow. ")
        XCTAssertEqual(Polish.accept("\n<text>\nHello there.\n</text>\n", for: "\nhello ther\n\n"), "\nHello there.\n\n")
        XCTAssertEqual(Polish.accept("\"Hello there.\"", for: "hello ther"), "Hello there.")
        XCTAssertEqual(Polish.accept("“Hello there.”", for: "hello ther"), "Hello there.")
        XCTAssertEqual(Polish.accept("\"Hello there.\"", for: "\"hello ther\""), "\"Hello there.\"", "the user's own quotes stay")
    }

    func testTheModelIsToldTheInstructionAndOnlyToRewrite() {
        XCTAssertTrue(Polish.system.contains("Never reply to the text"))
        XCTAssertEqual(Polish.message("Make it rhyme.", "hi"), "Instruction: Make it rhyme.\n<text>\nhi\n</text>")
        for e in Polish.examples { XCTAssertEqual(Polish.accept(e.answer, for: e.text), e.answer, "the examples pass the check") }
        XCTAssertEqual(Polish.words(" one two\nthree "), 3)
    }

    // MARK: the shortcut

    func testThePolishShortcutIsCtrlCmdPAndStartsNoDictation() {
        let s = Shortcuts()
        XCTAssertEqual(s.chord(.polish), [Key.ctrl, Key.cmd, Key.p])
        XCTAssertNil(s.problem(s.chord(.polish), for: .polish))
        XCTAssertEqual(Key.label(s.chord(.polish)), "⌃ ⌘ P")
        XCTAssertEqual(ShortcutAction.polish.title, "Polish selected text")
        XCTAssertEqual(s.problem([Key.ctrl, Key.cmd, Key.v], for: .polish), .inUse, "paste last's chord")

        var r = KeyRouter()
        XCTAssertEqual(r.key(Key.ctrl, down: true, active: false, canSwallow: true).inputs, [])
        XCTAssertEqual(r.key(Key.cmd, down: true, active: false, canSwallow: true).inputs, [])
        let out = r.key(Key.p, down: true, active: false, canSwallow: true)
        XCTAssertEqual(out.inputs, [.polish])
        XCTAssertTrue(out.swallow, "the front app never sees the P")
        XCTAssertTrue(r.key(Key.p, down: false, active: false, canSwallow: true).swallow)

        var g = FnGesture()
        XCTAssertEqual(g.handle(.polish, at: 1), [])
        XCTAssertEqual(g.state, .idle)

        // Rebound and stored like any other action.
        var mine = Shortcuts()
        XCTAssertNil(mine.set([Key.ctrl, Key.opt, Key.p], for: .polish))
        XCTAssertEqual(Shortcuts(stored: mine.stored).chord(.polish), [Key.ctrl, Key.opt, Key.p])
        XCTAssertEqual(mine.action(held: [Key.ctrl, Key.opt, Key.p]), .polish)
    }

    // MARK: history

    func testPolishRowsKeepTheInputAndOutputNewestFirst() throws {
        let first = PolishEntry(id: "p1", createdAt: Date(timeIntervalSince1970: 1000), outcome: .inserted, app: "TextEdit",
                                bundleId: "com.apple.TextEdit", promptName: "Polish", instruction: "Fix it.",
                                input: "teh fox ", output: "The fox. ")
        let second = PolishEntry(id: "p2", createdAt: Date(timeIntervalSince1970: 2000), outcome: .pasteFailed, app: "Slack",
                                 bundleId: "com.tinyspeck.slackmacgap", promptName: "Shorter", instruction: "Shorter.",
                                 input: "a b c", output: "a c")
        try History(path: dbURL).addPolish(first)
        try History(path: dbURL).addPolish(second)
        XCTAssertEqual(try History(path: dbURL).polishes(), [second, first], "after a reopen")
        XCTAssertEqual(try History(path: dbURL).polishes(limit: 1), [second])
        XCTAssertEqual(try History(path: dbURL).recent(), [], "a Polish is not a dictation")
        XCTAssertFalse(first.undone)
    }

    // A history.sqlite from the build before Polish (schema 3) opens with its dictations and gets the polish table.
    func testSchema3DatabaseGetsThePolishTableAndKeepsItsRows() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, History.migrations[0...2].joined() + """
            PRAGMA user_version = 3;
            INSERT INTO history VALUES ('a', 1000, 'inserted', '/old/a.wav', 1500, 'parakeet', 'hi there', 'Hi there',
                                        'Notes', 'com.apple.Notes', '', 0, 1);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let history = try History(path: dbURL)
        XCTAssertEqual(try history.recent().map(\.id), ["a"])
        XCTAssertEqual(try history.recent().first?.reverted, true)
        try history.addPolish(PolishEntry(id: "p", outcome: .inserted, promptName: "Polish", instruction: "i", input: "a", output: "A"))
        XCTAssertEqual(try History(path: dbURL).polishes().map(\.output), ["A"])
    }
}
