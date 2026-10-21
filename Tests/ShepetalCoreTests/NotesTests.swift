import XCTest
@testable import ShepetalCore

/// Scratchpad notes (F55): what is typed must still be there after a quit and relaunch, the pinned notes come first,
/// and the file is the user's alone, like history.sqlite and meetings.sqlite.
final class NotesTests: XCTestCase {
    var root: URL!
    var dbURL: URL { root.appendingPathComponent("notes.sqlite") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func note(_ id: String, updated t: Double, pinned: Bool = false, title: String = "") -> Note {
        Note(id: id, title: title, body: "", pinned: pinned, createdAt: Date(timeIntervalSince1970: 1_000),
             updatedAt: Date(timeIntervalSince1970: t))
    }

    // A relaunch opens the file again: every field comes back as it was saved, Markdown and line breaks included.
    func testNotesRoundTripAfterReopen() throws {
        let saved = Note(id: "a", title: "Groceries", body: "# Today\n\n- [ ] milk\n- **bread** · ünïcode 🤫",
                         pinned: true, createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000))
        try NoteStore(path: dbURL).save(saved)
        XCTAssertEqual(try NoteStore(path: dbURL).list(), [saved])
        XCTAssertEqual(try NoteStore(path: dbURL).list(), [saved], "and on every later launch (the migration runs once)")
    }

    // Saving again is an edit of the same note, never a second copy, and the note keeps the day it was made.
    func testSavingAgainUpdatesTheSameNote() throws {
        let store = try NoteStore(path: dbURL)
        var n = note("a", updated: 1_000, title: "Draft")
        try store.save(n)
        n.title = "Final"
        n.body = "done"
        n.updatedAt = Date(timeIntervalSince1970: 3_000)
        try store.save(n)
        XCTAssertEqual(try store.list(), [n])
        XCTAssertEqual(try store.list().first?.createdAt, Date(timeIntervalSince1970: 1_000))
    }

    // The list Pavel sees: pinned notes on top, newest change first within each group, whatever order they were saved in.
    func testPinnedNotesComeFirstThenTheNewestChange() throws {
        let store = try NoteStore(path: dbURL)
        for n in [note("old", updated: 1_000), note("pinnedOld", updated: 1_500, pinned: true), note("new", updated: 3_000),
                  note("pinnedNew", updated: 2_000, pinned: true)] { try store.save(n) }
        XCTAssertEqual(try store.list().map(\.id), ["pinnedNew", "pinnedOld", "new", "old"])
        XCTAssertEqual(try NoteStore(path: dbURL).list().map(\.id), ["pinnedNew", "pinnedOld", "new", "old"], "after a relaunch too")
    }

    // Notes can hold anything the user dictates: only the owner may read the file (0600), and it stays so after a reopen.
    func testTheFileIsOwnerOnly() throws {
        try NoteStore(path: dbURL).save(note("a", updated: 1_000))
        func mode() throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dbURL.path)[.posixPermissions] as? NSNumber).intValue
        }
        XCTAssertEqual(try mode(), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
        _ = try NoteStore(path: dbURL)
        XCTAssertEqual(try mode(), 0o600, "a file loosened outside shepetal is tightened at the next launch")
    }

    func testDeleteRemovesOnlyThatNote() throws {
        let store = try NoteStore(path: dbURL)
        try store.save(note("a", updated: 1_000))
        try store.save(note("b", updated: 2_000))
        try store.delete("a")
        XCTAssertEqual(try store.list().map(\.id), ["b"])
        XCTAssertEqual(try NoteStore(path: dbURL).list().map(\.id), ["b"], "gone after a relaunch, not hidden")
        XCTAssertNoThrow(try store.delete("a"), "deleting it twice does nothing")
    }
}
