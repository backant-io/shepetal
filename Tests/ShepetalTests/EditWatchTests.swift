import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F26's watch on the pasted field. The field, the focus and the clock are fakes: no AX call is made, no app is
/// touched, focus never moves, and the clipboard is never read. Elements are AXUIElement references for made-up
/// pids, which are only compared, never asked anything.
@MainActor
final class EditWatchTests: XCTestCase {
    let pastedField = AXUIElementCreateApplication(99_001)
    let otherField = AXUIElementCreateApplication(99_002)
    var focused: AXUIElement?
    var texts: [AXUIElement: String] = [:]
    var secureFields: Set<AXUIElement> = []
    var secureInput = false
    var clock: TimeInterval = 1000
    /// Every element whose text was read.
    var read: [AXUIElement] = []
    var ended: [(EditWatch.End, [AutoLearn.Pair])] = []

    var reader: EditWatch.Reader {
        EditWatch.Reader(focused: { [unowned self] in focused },
                         isSecure: { [unowned self] in secureFields.contains($0) },
                         text: { [unowned self] in read.append($0); return texts[$0] })
    }

    override func setUp() {
        focused = pastedField
        texts = [pastedField: "Hi team, send it to jon by Friday. Thanks", otherField: "Other field with jon"]
    }

    /// TextEdit at paste time: "Hi team, " + the paste + " Thanks".
    func watch() throws -> EditWatch {
        try XCTUnwrap(EditWatch(pasted: "send it to jon by Friday.", before: "Hi team, ", after: " Thanks", reader: reader,
                                secureInput: { [unowned self] in secureInput }, now: { [unowned self] in clock },
                                done: { [unowned self] in ended.append(($0, $1)) }))
    }

    func fix() { texts[pastedField] = "Hi team, send it to John by Friday. Thanks" }

    func testFixIsLearnedWhenFocusLeavesAndOnlyThePastedElementIsRead() throws {
        let w = try watch()
        w.poll()
        XCTAssertTrue(w.verified, "the field holds before + paste + after")
        clock += 3
        fix()
        w.poll()
        focused = otherField
        clock += 1
        w.poll()
        XCTAssertEqual(w.end, .focusLeft)
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.1, [AutoLearn.Pair(heard: "jon", corrected: "John")])
        XCTAssertFalse(read.contains(otherField), "the field that took focus is never read")
        XCTAssertEqual(read.count, 2)
        w.poll()
        w.stop(.nextDictation)
        XCTAssertEqual(ended.count, 1, "it ends once")
    }

    func testStopsAfter60Seconds() throws {
        let w = try watch()
        w.poll()
        fix()
        clock += 59.9
        w.poll()
        XCTAssertNil(w.end)
        clock += 0.1
        w.poll()
        XCTAssertEqual(w.end, .timeout)
        XCTAssertEqual(ended.first?.1, [AutoLearn.Pair(heard: "jon", corrected: "John")], "what it saw by then is learned")
        XCTAssertEqual(read.count, 2, "no read after the window")
        XCTAssertEqual(EditWatch.window, 60)
    }

    func testSecureFieldOrSecureInputStopsAndLearnsNothing() throws {
        var w = try watch()
        w.poll()
        fix()
        w.poll()
        secureFields = [pastedField]
        w.poll()
        XCTAssertEqual(w.end, .secure)
        XCTAssertEqual(ended.last?.1, [], "nothing is learned from a field that turned out to be secure")
        XCTAssertEqual(read.count, 2, "a secure field's text is never read")

        secureFields = []
        texts[pastedField] = "Hi team, send it to jon by Friday. Thanks"
        read = []
        w = try watch()
        w.poll()
        fix()
        secureInput = true
        w.poll()
        XCTAssertEqual(w.end, .secure)
        XCTAssertEqual(ended.last?.1, [])
        XCTAssertEqual(read.count, 1, "nothing is read while Secure Input is on")
    }

    func testNextDictationStopsAndLearns() throws {
        let w = try watch()
        w.poll()
        fix()
        w.poll()
        w.stop(.nextDictation)
        XCTAssertEqual(ended.first?.0, .nextDictation)
        XCTAssertEqual(ended.first?.1, [AutoLearn.Pair(heard: "jon", corrected: "John")])
    }

    /// The field never showed the paste where it was expected (an app whose text cannot be read, or a context read
    /// that came back empty): nothing is known about the span, so nothing is learned.
    func testAFieldThatNeverShowedThePasteLearnsNothing() throws {
        texts[pastedField] = "Hi team, send it to John by Friday. Thanks"  // already changed before the first look
        let w = try watch()
        w.poll()
        XCTAssertFalse(w.verified)
        w.stop(.nextDictation)
        XCTAssertEqual(ended.first?.1, [])

        let blank = try XCTUnwrap(EditWatch(pasted: "send it to jon", before: "", after: "", reader: reader, secureInput: { false },
                                            now: { [unowned self] in clock }, done: { [unowned self] in ended.append(($0, $1)) }))
        texts[pastedField] = "Notes\nsend it to John"
        blank.poll()
        blank.stop(.timeout)
        XCTAssertEqual(ended.last?.1, [], "with no context the whole field is the span, and it never equalled the paste")
    }

    func testSentMessageKeepsTheLastFixSeen() throws {
        let w = try watch()
        w.poll()
        fix()
        w.poll()
        texts[pastedField] = ""  // Return sent it; the field is empty and keeps focus
        w.poll()
        w.stop(.timeout)
        XCTAssertEqual(ended.first?.1, [AutoLearn.Pair(heard: "jon", corrected: "John")])
    }

    func testNoFocusedElementStartsNoWatch() {
        focused = nil
        XCTAssertNil(EditWatch(pasted: "x", before: "", after: "", reader: reader, secureInput: { false }, done: { _, _ in }))
    }

    /// Rule 8 and Pavel's rules for the Mac: the watch reads and nothing else.
    func testTheWatchOnlyReads() throws {
        let source = try AppSource.code("EditWatch.swift")
        for call in ["AXUIElementSetAttributeValue", "AXUIElementPerformAction", "activate(", "NSPasteboard", "orderFront",
                     "makeKey", "CGEvent", "askForTree"] {
            XCTAssertFalse(source.contains(call), call)
        }
    }

    // MARK: AutoLearner: dictionary, hint, undo, setting

    func learner() throws -> (AutoLearner, URL, () -> [String]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-learn-\(UUID().uuidString)")
        try AudioStore.makeOwnerOnlyDirectory(dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let suite = "shepetal-learn-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var hints: [String] = []
        let l = AutoLearner(dictionary: dir.appendingPathComponent("dictionary.txt")) { hints.append($0) }
        l.defaults = defaults
        l.reader = reader
        l.secureInput = { [unowned self] in secureInput }
        l.now = { [unowned self] in clock }
        return (l, l.dictionary, { hints })
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        MenuModel.build(MenuModel.groups(MenuState()), into: menu, target: self, action: #selector(noop(_:)))
        return menu
    }

    @objc private func noop(_ sender: NSMenuItem) {}

    /// M-LEARN-1 in code: fix a word, see "Learned", the next dictation's text is right; undo from 🤫 forgets it.
    func testLearnedWordGoesToTheDictionaryWithAHintAndUndoForgetsIt() throws {
        let (l, url, hints) = try learner()
        let mine = "# my words\nKubernetes"
        try Data(mine.utf8).write(to: url)
        let m = menu()
        let plain = m.items.map(\.title)
        l.addMenuItem(to: m)
        XCTAssertEqual(m.items.map(\.title), plain, "nothing learned: no undo item")

        l.pasted("send it to jon by Friday.", into: (before: "Hi team, ", after: " Thanks", selected: ""))
        fix()
        l.watch?.poll()
        l.dictationStarted()
        XCTAssertNil(l.watch)
        XCTAssertEqual(hints(), ["Learned: John"])
        XCTAssertEqual(Vocabulary.load(url).apply("Ask jon"), "Ask John", "the next dictation writes it right")

        let withUndo = menu()
        l.addMenuItem(to: withUndo)
        let item = try XCTUnwrap(withUndo.items.first)
        XCTAssertEqual(item.title, "Forget learned “John”")
        XCTAssertTrue(item.isEnabled, "never grey")
        XCTAssertTrue(withUndo.items[1].isSeparatorItem, "its own group above the meetings")
        XCTAssertNotNil(item.action)
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        XCTAssertEqual(try Data(contentsOf: url), Data(mine.utf8), "the file is as it was before the learn")
        XCTAssertEqual(hints().last, "Forgot “John”")
        let after = menu()
        l.addMenuItem(to: after)
        XCTAssertEqual(after.items.map(\.title), plain, "undone: the item is gone")
    }

    func testUndoItemJoinsWhatNeedsDoing() throws {
        let (l, _, _) = try learner()
        l.learn([AutoLearn.Pair(heard: "github", corrected: "GitHub")])
        let m = NSMenu()
        MenuModel.build(MenuModel.groups(MenuState(permissionsMissing: true)), into: m, target: self, action: #selector(noop(_:)))
        l.addMenuItem(to: m)
        XCTAssertEqual(Array(m.items.prefix(2).map(\.title)), ["Forget learned “GitHub”", "Permissions needed…"])
    }

    func testSettingIsOnByDefaultAndOffWatchesNothing() throws {
        let (l, url, hints) = try learner()
        XCTAssertTrue(AutoLearner.isOn(l.defaults), "on by default, as in Wispr")
        l.defaults.set(false, forKey: AutoLearner.settingKey)
        l.pasted("send it to jon by Friday.", into: (before: "Hi team, ", after: " Thanks", selected: ""))
        XCTAssertNil(l.watch)
        XCTAssertTrue(read.isEmpty, "the field is not even read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(hints(), [])
    }

    func testANewPasteEndsTheLastWatch() throws {
        let (l, _, hints) = try learner()
        l.pasted("send it to jon by Friday.", into: (before: "Hi team, ", after: " Thanks", selected: ""))
        fix()
        l.watch?.poll()
        let first = l.watch
        l.pasted("Thanks", into: (before: "Hi team, send it to John by Friday. ", after: "", selected: ""))
        XCTAssertEqual(first?.end, .nextDictation)
        XCTAssertEqual(hints(), ["Learned: John"])
        l.dictationStarted()
    }
}
