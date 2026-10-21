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
    /// The frontmost app at dictation start, and the page URL when it is a browser. Never leaves the Mac.
    public var app: String
    public var bundleId: String
    public var url: String
    public var archived: Bool
    /// The user switched this row back to what was heard (F48, Wispr's hasRevertedAI). `text` is kept.
    public var reverted: Bool

    public init(id: String, createdAt: Date, outcome: Outcome, audioPath: String,
                durationMs: Int, model: String = "", rawText: String = "", text: String = "",
                app: String = "", bundleId: String = "", url: String = "", archived: Bool = false, reverted: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.outcome = outcome; self.audioPath = audioPath
        self.durationMs = durationMs; self.model = model; self.rawText = rawText; self.text = text
        self.app = app; self.bundleId = bundleId; self.url = url; self.archived = archived; self.reverted = reverted
    }

    /// What History shows and copies, and what paste last and copy last use: the raw transcript without its
    /// non-speech tags once the row is reverted, else the cleaned text.
    public var shownText: String { reverted ? AppFormat.asHeard(rawText) : text }

    /// Play and re-transcribe need the kept WAV. It is gone after the 24 h retention ran, or when saving it failed.
    public func canReplay(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Bool {
        !audioPath.isEmpty && fileExists(audioPath)
    }
}

/// Apps whose page URL is stored with the dictation: Safari, the Chrome family, Arc, Edge, Brave,
/// Firefox, Vivaldi and Opera.
public enum Browser {
    public static let bundleIds: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
    ]

    public static func contains(_ bundleId: String) -> Bool { bundleIds.contains(bundleId) }

    /// The part of a page URL that history keeps: scheme, host and path. Query, fragment, path parameters,
    /// user, password and port are dropped, because they can carry sign-in codes, session ids and reset tokens the user never
    /// dictated. A URL without a host (file:, about:, data:) is not kept at all.
    public static func historyURL(_ s: String) -> String {
        guard let c = URLComponents(string: s), let scheme = c.scheme, let host = c.host, !host.isEmpty else { return "" }
        var kept = URLComponents()
        kept.scheme = scheme
        kept.host = host
        // Path parameters (";jsessionid=...") are cut too.
        kept.percentEncodedPath = String(c.percentEncodedPath.prefix { $0 != ";" })
        return kept.string ?? ""
    }
}

/// One row per recording, in SQLite through the system library. The file is owner-only (0600).
public final class History {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = "id, created_at, outcome, audio_path, duration_ms, model, raw_text, text, app, bundle_id, url, archived, reverted"

    /// Schema steps; `PRAGMA user_version` counts how many ran. Append only: a file from an older build
    /// runs just the steps it is missing, and keeps its rows.
    static let migrations = [
        // 1: iteration 1
        """
        CREATE TABLE IF NOT EXISTS history(
          id TEXT PRIMARY KEY, created_at REAL NOT NULL, outcome TEXT NOT NULL, audio_path TEXT NOT NULL,
          duration_ms INTEGER NOT NULL, model TEXT NOT NULL, raw_text TEXT NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS history_created ON history(created_at);
        """,
        // 2: app context (F23) and archive (F52)
        """
        ALTER TABLE history ADD COLUMN app TEXT NOT NULL DEFAULT '';
        ALTER TABLE history ADD COLUMN bundle_id TEXT NOT NULL DEFAULT '';
        ALTER TABLE history ADD COLUMN url TEXT NOT NULL DEFAULT '';
        ALTER TABLE history ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;
        """,
        // 3: undo cleanup (F48)
        "ALTER TABLE history ADD COLUMN reverted INTEGER NOT NULL DEFAULT 0;",
    ]

    public init(path: URL) throws {
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw error("open")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        sqlite3_busy_timeout(db, 2000)  // an old instance still writing during an upgrade waits instead of failing
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        // The statement is finalized before the migrations run: an open read locks tables a migration may drop.
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

    public func add(_ e: HistoryEntry) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO history(\(Self.columns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, e.id)
        sqlite3_bind_double(stmt, 2, e.createdAt.timeIntervalSince1970)
        bind(stmt, 3, e.outcome.rawValue)
        bind(stmt, 4, e.audioPath)
        sqlite3_bind_int64(stmt, 5, Int64(e.durationMs))
        bind(stmt, 6, e.model)
        bind(stmt, 7, e.rawText)
        bind(stmt, 8, e.text)
        bind(stmt, 9, e.app)
        bind(stmt, 10, e.bundleId)
        bind(stmt, 11, Browser.historyURL(e.url))
        sqlite3_bind_int64(stmt, 12, e.archived ? 1 : 0)
        sqlite3_bind_int64(stmt, 13, e.reverted ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("insert") }
    }

    /// A re-transcription: new model, raw text and text on the same row. Its time, outcome, audio and
    /// app stay as they were.
    public func update(_ e: HistoryEntry) throws {
        let stmt = try prepare("UPDATE history SET model = ?, raw_text = ?, text = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, e.model)
        bind(stmt, 2, e.rawText)
        bind(stmt, 3, e.text)
        bind(stmt, 4, e.id)
        try stepChangingOneRow(stmt, "update")
    }

    public func setArchived(_ id: String, _ archived: Bool) throws {
        let stmt = try prepare("UPDATE history SET archived = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, archived ? 1 : 0)
        bind(stmt, 2, id)
        try stepChangingOneRow(stmt, "archive")
    }

    /// Show raw / Show cleaned (F48). Only the flag changes, so switching back gives the cleaned text again.
    public func setReverted(_ id: String, _ reverted: Bool) throws {
        let stmt = try prepare("UPDATE history SET reverted = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, reverted ? 1 : 0)
        bind(stmt, 2, id)
        try stepChangingOneRow(stmt, "revert")
    }

    /// Newest first, archived rows included.
    public func recent(limit: Int = 20) throws -> [HistoryEntry] {
        try search("", includeArchived: true, limit: limit)
    }

    /// Rows whose text or raw text contains `query` (any case), newest first. An empty query matches all.
    /// ponytail: a LIKE scan over every row, and LIKE folds ASCII case only; move to FTS5 if it gets slow
    /// or non-ASCII case matters.
    public func search(_ query: String, includeArchived: Bool = false, limit: Int = 50) throws -> [HistoryEntry] {
        let stmt = try prepare("""
            SELECT \(Self.columns) FROM history
            WHERE (text LIKE ?1 ESCAPE '\\' OR raw_text LIKE ?1 ESCAPE '\\') AND (?2 OR archived = 0)
            ORDER BY created_at DESC LIMIT ?3
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, "%" + Self.escapeLike(query) + "%")
        sqlite3_bind_int64(stmt, 2, includeArchived ? 1 : 0)
        sqlite3_bind_int64(stmt, 3, Int64(limit))
        var rows: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
            func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
            rows.append(HistoryEntry(
                id: text(0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                outcome: Outcome(rawValue: text(2)) ?? .failed, audioPath: text(3), durationMs: int(4),
                model: text(5), rawText: text(6), text: text(7),
                app: text(8), bundleId: text(9), url: text(10), archived: int(11) != 0, reverted: int(12) != 0))
        }
        return rows
    }

    /// Every app dictated into, by bundle id, under the name of its newest row, sorted by name: the rows of
    /// Formatting per app (F33). Rows without a bundle id are left out.
    public func apps() throws -> [(name: String, bundleId: String)] {
        // A bare column next to MAX() comes from the row holding the max (SQLite), so the newest name wins.
        let stmt = try prepare("""
            SELECT app, bundle_id, MAX(created_at) FROM history WHERE bundle_id != ''
            GROUP BY bundle_id ORDER BY app COLLATE NOCASE, bundle_id
            """)
        defer { sqlite3_finalize(stmt) }
        var apps: [(name: String, bundleId: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            apps.append((String(cString: sqlite3_column_text(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1))))
        }
        return apps
    }

    /// Totals over the delivered dictations (inserted and paste_failed, archived rows included) made at
    /// or after `since`. too_short, cancelled, no_speech and failed rows are not counted.
    /// ponytail: scans every delivered row and counts words in Swift; keep a word_count column if it gets slow.
    public func stats(since: Date = .distantPast, typingWpm: Double = DictationStats.defaultTypingWpm) throws -> DictationStats {
        let stmt = try prepare("""
            SELECT app, text, duration_ms FROM history
            WHERE outcome IN ('\(Outcome.inserted.rawValue)', '\(Outcome.pasteFailed.rawValue)') AND created_at >= ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        var s = DictationStats(typingWpm: typingWpm)
        var byApp: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let app = String(cString: sqlite3_column_text(stmt, 0))
            let words = DictationStats.wordCount(String(cString: sqlite3_column_text(stmt, 1)))
            s.dictations += 1
            s.words += words
            s.speakingMs += Int(sqlite3_column_int64(stmt, 2))
            byApp[app.isEmpty ? "unknown app" : app, default: 0] += words
        }
        s.apps = byApp.map { DictationStats.AppWords(app: $0.key, words: $0.value) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.app < $1.app }
        return s
    }

    /// `%` and `_` in what the user typed are literal characters, not LIKE wildcards.
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(stmt, i, s, -1, Self.transient)
    }

    private func stepChangingOneRow(_ stmt: OpaquePointer?, _ op: String) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error(op) }
        guard sqlite3_changes(db) == 1 else {
            throw NSError(domain: "History", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(op): no such entry"])
        }
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

/// The Home tab's "Your stats" (F60), from `History.stats(since:typingWpm:)`. All zeros when nothing was dictated.
public struct DictationStats: Equatable {
    public struct AppWords: Equatable {
        public var app: String
        public var words: Int
    }

    /// The typing speed "time saved" is measured against. The `typingWpm` user default overrides it.
    public static let defaultTypingWpm = 40.0

    public var dictations = 0
    public var words = 0
    public var speakingMs = 0
    public var typingWpm = defaultTypingWpm
    /// Every app with a delivered dictation, most words first, ties by name. "unknown app" when none was recorded.
    public var apps: [AppWords] = []

    public init(typingWpm: Double = defaultTypingWpm) { self.typingWpm = typingWpm }

    public var speakingMinutes: Double { Double(speakingMs) / 60_000 }
    public var wpm: Double { speakingMs > 0 ? Double(words) / speakingMinutes : 0 }
    /// Typing the same words at `typingWpm`, minus the time spent speaking them; never below zero.
    public var timeSavedMinutes: Double { typingWpm > 0 ? max(0, Double(words) / typingWpm - speakingMinutes) : 0 }

    /// Words as the system's word breaks see them: punctuation is not a word, and Chinese or Japanese without spaces still splits.
    static func wordCount(_ s: String) -> Int {
        var n = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }
}
