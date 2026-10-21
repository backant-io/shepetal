import AppKit
import ShepetalCore
import SwiftUI
import XCTest
@testable import Shepetal

/// The notes window (F55). Its tabs only write down what they are asked to do and activating the app is a closure,
/// so these tests never put a window on screen, take focus or touch the clipboard; the store is a temp file.
@MainActor
final class NotesWindowTests: XCTestCase {
    /// Never on screen: showing it, making it key and joining a tab group are only recorded.
    final class RecordingTab: NoteTab {
        var calls: [String] = []
        var joined: [NoteTab] = []
        override func makeKeyAndOrderFront(_ sender: Any?) { calls.append("makeKeyAndOrderFront") }
        override func orderFront(_ sender: Any?) { calls.append("orderFront") }
        override func makeKey() { calls.append("makeKey") }
        override func addTabbedWindow(_ window: NSWindow, ordered: NSWindow.OrderingMode) { joined.append(window as! NoteTab) }
    }

    /// Records the paste instead of reading a pasteboard.
    final class RecordingText: NSTextView {
        var pastes = 0
        override func paste(_ sender: Any?) { pastes += 1 }
    }

    private var root: URL!
    private var made: [RecordingTab] = []
    private var activations = 0
    private var clock = 1_000.0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-notes-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var dbURL: URL { root.appendingPathComponent("notes.sqlite") }

    /// Every change one second after the last, so the order never depends on how fast the test runs.
    private func model(saveDelay: TimeInterval = 60) throws -> NotesModel {
        NotesModel(store: try NoteStore(path: dbURL), saveDelay: saveDelay, now: { [unowned self] in
            clock += 1
            return Date(timeIntervalSince1970: clock)
        })
    }

    private func windows(_ model: NotesModel) -> NotesWindow {
        NotesWindow(model: model, makeTab: { [unowned self] in
            let t = RecordingTab()
            made.append(t)
            return t
        }, activate: { [unowned self] in activations += 1 })
    }

    // The shortcut or the menu with no notes yet gives a note to dictate into, in front and with the keyboard.
    func testShowOpensANoteToTypeIntoEvenWhenThereIsNone() throws {
        let w = windows(try model())
        w.show()
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].calls, ["makeKeyAndOrderFront"], "key, so dictation pastes into it")
        XCTAssertEqual(activations, 1, "shepetal comes to the front: the user asked for the window")
        XCTAssertEqual(try NoteStore(path: dbURL).list().count, 1, "the new note is saved at once")
        XCTAssertEqual(made[0].title, "Untitled")
        XCTAssertTrue(made[0].contentView is NSHostingView<NoteView>)
        XCTAssertEqual(made[0].tabbingMode, .preferred)

        w.show()
        XCTAssertEqual(made.count, 1, "pressed again: the same window to the front, no second note")
        XCTAssertEqual(made[0].calls, ["makeKeyAndOrderFront", "makeKeyAndOrderFront"])
        XCTAssertEqual(try NoteStore(path: dbURL).list().count, 1)
    }

    // A second note opens as a tab of the window already open; a note that is open is brought back, never opened twice.
    func testASecondNoteOpensAsATabAndAnOpenNoteIsNotOpenedTwice() throws {
        let m = try model()
        let a = m.create(), b = m.create()
        let w = windows(m)
        w.open(a.id)
        w.open(b.id)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].joined, [made[1]], "b joins a's window as a tab")
        XCTAssertEqual(made[1].joined, [])
        XCTAssertEqual(w.tabs.map { $0.id }, [a.id, b.id])

        w.open(a.id)
        XCTAssertEqual(made.count, 2, "a already has a tab")
        XCTAssertEqual(made[0].calls.last, "makeKeyAndOrderFront", "its tab is selected")
        let (aShown, bShown) = (made[0].calls.count, made[1].calls.count)
        w.show()
        XCTAssertEqual([made[0].calls.count, made[1].calls.count], [aShown + 1, bShown],
                       "the shortcut again keeps the tab in front, a, not the top note of the list, b")
        w.newNote()
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(made[0].joined.last, made[2], "a new note joins the tab in front, a")

        made[1].close()
        XCTAssertEqual(w.tabs.count, 2, "a closed tab is forgotten")
        w.open(b.id)
        XCTAssertEqual(made.count, 4, "and opens again as a new tab")
        XCTAssertEqual(try NoteStore(path: dbURL).list().count, 3, "closing a tab keeps its note")
    }

    // Pinning moves the note to the Pinned section at the top, there after a relaunch; unpinning puts it back by its date.
    func testPinMovesTheNoteToTheTopAndARelaunchKeepsIt() throws {
        let m = try model()
        let older = m.create(), newer = m.create()
        XCTAssertEqual(m.notes.map(\.id), [newer.id, older.id], "newest change first")
        m.setPinned(older.id, true)
        XCTAssertEqual(m.notes.map(\.id), [older.id, newer.id])
        XCTAssertEqual(try NoteStore(path: dbURL).list().map(\.id), [older.id, newer.id], "saved at once, not after the delay")
        XCTAssertEqual(try model().notes.map(\.id), [older.id, newer.id], "a relaunch keeps the pinned note first")
        m.setPinned(older.id, false)
        XCTAssertEqual(m.notes.map(\.id), [newer.id, older.id], "pinning is not an edit")
    }

    // Typing waits for a pause before it writes, but closing the tab or quitting never loses the last words.
    func testTypingIsSavedAfterAPauseAndWhenTheTabCloses() async throws {
        let m = try model(saveDelay: 0.05)
        let a = m.create(), b = m.create()
        m.edit(a.id, title: "Call Anna", body: "about the 21.10.26 invoice")
        XCTAssertEqual(m.notes.first?.id, a.id, "the note just typed in comes first")
        XCTAssertEqual(try NoteStore(path: dbURL).list().first { $0.id == a.id }?.body, "", "not on every keystroke")
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(try NoteStore(path: dbURL).list().first { $0.id == a.id }?.body, "about the 21.10.26 invoice")

        let slow = try model(saveDelay: 60)
        let w = windows(slow)
        w.open(b.id)
        slow.edit(b.id, title: "", body: "last words")
        XCTAssertEqual(made[0].title, "Untitled")
        slow.edit(b.id, title: "Ideas", body: "last words")
        XCTAssertEqual(made[0].title, "Ideas", "the tab is named after its note")
        made[0].close()
        XCTAssertEqual(try NoteStore(path: dbURL).list().first { $0.id == b.id }?.body, "last words", "saved as the tab closes")

        slow.edit(b.id, title: "Ideas", body: "said just before quitting")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: self)  // not NSApp's: AppKit's own observers stay out of it
        XCTAssertEqual(try NoteStore(path: dbURL).list().first { $0.id == b.id }?.body, "said just before quitting")
    }

    // Delete removes the note and closes its tab; an edit still waiting to be saved cannot bring it back.
    func testDeleteClosesItsTabAndAWaitingSaveCannotBringItBack() async throws {
        let m = try model(saveDelay: 0.05)
        let a = m.create(), b = m.create()
        let w = windows(m)
        w.open(a.id)
        w.open(b.id)
        m.edit(a.id, title: "", body: "typed, then deleted")
        w.delete(a.id)
        XCTAssertEqual(w.tabs.map { $0.id }, [b.id])
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(try NoteStore(path: dbURL).list().map(\.id), [b.id])
        XCTAssertEqual(m.notes.map(\.id), [b.id])
    }

    // Shepetal has no Edit menu, so without this ⌘V reached no text view and every dictation into a note was lost
    // to the clipboard. The paste goes to the text being edited, on any layout.
    func testDictationsPasteReachesTheNoteBeingEdited() throws {
        let tab = NoteTab()
        let text = RecordingText()
        tab.contentView = text
        XCTAssertTrue(tab.makeFirstResponder(text))
        func key(_ chars: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(tab.performKeyEquivalent(with: key("v", 9)))
        XCTAssertEqual(text.pastes, 1)
        XCTAssertTrue(tab.performKeyEquivalent(with: key("м", 9)), "Russian layout: the V key")
        XCTAssertEqual(text.pastes, 2)
        XCTAssertFalse(tab.performKeyEquivalent(with: key("v", 9, [.control, .command])), "⌃⌘V is paste last, not the editor's")
        XCTAssertEqual(text.pastes, 2)

        XCTAssertEqual(NoteTab.editAction(key("c", 8)), #selector(NSText.copy(_:)))
        XCTAssertEqual(NoteTab.editAction(key("z", 6)), Selector(("undo:")))
        XCTAssertEqual(NoteTab.editAction(key("Z", 6, [.command, .shift])), Selector(("redo:")))
        XCTAssertEqual(NoteTab.editAction(key("v", 47)), #selector(NSText.paste(_:)), "Dvorak: by the letter, not the key")
        XCTAssertNil(NoteTab.editAction(key("n", 45)))
    }
}
