import Foundation
import SQLite3

public enum Outcome: String {
    case inserted
    case pasteFailed = "paste_failed"  // text kept here; nothing pulled it from the clipboard
    case tooShort = "too_short"
    case cancelled
    case failed                        // transcription error
    case noSpeech = "no_speech"        // silence, non-speech tags or fillers only; nothing pasted
}

public struct HistoryEntry: Equatable {
    public var id: String
    public var createdAt: Date
    public var outcome: Outcome
    public var audioPath: String
    public var durationMs: Int
    public var model: String
    public var rawText: String
    public var text: String

    public init(id: String, createdAt: Date, outcome: Outcome, audioPath: String,
                durationMs: Int, model: String = "", rawText: String = "", text: String = "") {
        self.id = id; self.createdAt = createdAt; self.outcome = outcome; self.audioPath = audioPath
        self.durationMs = durationMs; self.model = model; self.rawText = rawText; self.text = text
    }
}

/// One row per recording, in SQLite through the system library. The file is owner-only (0600).
public final class History {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL) throws {
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw error("open")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try exec("""
            CREATE TABLE IF NOT EXISTS history(
              id TEXT PRIMARY KEY, created_at REAL NOT NULL, outcome TEXT NOT NULL, audio_path TEXT NOT NULL,
              duration_ms INTEGER NOT NULL, model TEXT NOT NULL, raw_text TEXT NOT NULL, text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS history_created ON history(created_at);
            """)
    }

    deinit { sqlite3_close(db) }

    public func add(_ e: HistoryEntry) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO history VALUES (?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, e.id, -1, Self.transient)
        sqlite3_bind_double(stmt, 2, e.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, e.outcome.rawValue, -1, Self.transient)
        sqlite3_bind_text(stmt, 4, e.audioPath, -1, Self.transient)
        sqlite3_bind_int64(stmt, 5, Int64(e.durationMs))
        sqlite3_bind_text(stmt, 6, e.model, -1, Self.transient)
        sqlite3_bind_text(stmt, 7, e.rawText, -1, Self.transient)
        sqlite3_bind_text(stmt, 8, e.text, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("insert") }
    }

    /// Newest first.
    public func recent(limit: Int = 20) throws -> [HistoryEntry] {
        let stmt = try prepare("SELECT * FROM history ORDER BY created_at DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var rows: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
            rows.append(HistoryEntry(
                id: text(0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                outcome: Outcome(rawValue: text(2)) ?? .failed, audioPath: text(3),
                durationMs: Int(sqlite3_column_int64(stmt, 4)), model: text(5), rawText: text(6), text: text(7)))
        }
        return rows
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
        NSError(domain: "History", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: "\(op): \(String(cString: sqlite3_errmsg(db)))"])
    }
}
