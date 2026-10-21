import Foundation
import SQLite3

/// A scratchpad note (F55): a title and a Markdown body, kept on this Mac only.
public struct Note: Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Markdown, stored as typed.
    public var body: String
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, title: String = "", body: String = "", pinned: Bool = false,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.title = title; self.body = body; self.pinned = pinned
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    /// The list's order: pinned notes first, then the newest change. The id breaks ties, so the order never jumps.
    public static func precedes(_ a: Note, _ b: Note) -> Bool {
        (a.pinned ? 0 : 1, -a.updatedAt.timeIntervalSince1970, a.id) < (b.pinned ? 0 : 1, -b.updatedAt.timeIntervalSince1970, b.id)
    }
}

/// Notes in one owner-only (0600) SQLite file, through the system library, as History and MeetingStore do.
public final class NoteStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = "id, title, body, pinned, created_at, updated_at"

    /// Schema steps; `PRAGMA user_version` counts how many ran. Append only (images, F57, and versions come as new
    /// steps): a file from an older build runs just the steps it is missing, and keeps its notes.
    static let migrations = [
        // 1: notes (F55)
        """
        CREATE TABLE notes(
          id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, updated_at REAL NOT NULL);
        """,
    ]

    public init(path: URL) throws {
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw error("open")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA foreign_keys = ON")  // per connection: tables that hang off a note (F57) cascade on delete
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        let stmt = try prepare("PRAGMA user_version")
        guard sqlite3_step(stmt) == SQLITE_ROW else { sqlite3_finalize(stmt); throw error("user_version") }
        let version = Int(sqlite3_column_int64(stmt, 0))
        sqlite3_finalize(stmt)
        for step in version..<max(version, Self.migrations.count) {
            try exec("BEGIN IMMEDIATE")
            do {
                try exec(Self.migrations[step])
                try exec("PRAGMA user_version = \(step + 1)")
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Creates or updates the note. An upsert, not INSERT OR REPLACE: replacing deletes the row first, which would
    /// take everything that cascades from it (F57's images) along.
    public func save(_ n: Note) throws {
        let stmt = try prepare("""
            INSERT INTO notes(\(Self.columns)) VALUES (?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, body = excluded.body, pinned = excluded.pinned,
              updated_at = excluded.updated_at
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, n.id)
        bind(stmt, 2, n.title)
        bind(stmt, 3, n.body)
        sqlite3_bind_int64(stmt, 4, n.pinned ? 1 : 0)
        sqlite3_bind_double(stmt, 5, n.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, n.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("save") }
    }

    /// Deleting a note that is not there does nothing.
    public func delete(_ id: String) throws {
        let stmt = try prepare("DELETE FROM notes WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("delete") }
    }

    /// Every note, in the list's order (`Note.precedes`).
    public func list() throws -> [Note] {
        let stmt = try prepare("SELECT \(Self.columns) FROM notes")
        defer { sqlite3_finalize(stmt) }
        var notes: [Note] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
            func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: sqlite3_column_double(stmt, i)) }
            notes.append(Note(id: text(0), title: text(1), body: text(2), pinned: sqlite3_column_int64(stmt, 3) != 0,
                              createdAt: date(4), updatedAt: date(5)))
        }
        return notes.sorted(by: Note.precedes)
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(stmt, i, s, -1, Self.transient)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error("exec") }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare") }
        return stmt
    }

    private func error(_ op: String) -> NSError {
        NSError(domain: "Notes", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: "\(op): \(String(cString: sqlite3_errmsg(db)))"])
    }
}
