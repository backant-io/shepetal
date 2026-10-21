import Foundation
import SQLite3

/// Meetings, their segments, summaries, notes and folders in one owner-only (0600) SQLite file, through the system library.
/// App, segment, summary and notes text also go into an FTS5 trigram index, so search finds any substring in any case.
public final class MeetingStore: MeetingStoring {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = "id, app, started_at, ended_at, me_audio, others_audio"

    /// Schema steps; `PRAGMA user_version` counts how many ran, as in History. Append only: a file from an older
    /// build runs just the steps it is missing, and keeps its rows. Builds before notes left user_version at 0 with
    /// step 1's tables in place, which is why step 1 says IF NOT EXISTS.
    static let migrations = [
        // 1: meetings, segments, summaries and their search index (#113)
        """
        CREATE TABLE IF NOT EXISTS meetings(
          id TEXT PRIMARY KEY, app TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL,
          me_audio TEXT NOT NULL, others_audio TEXT NOT NULL, summary TEXT);
        CREATE INDEX IF NOT EXISTS meetings_started ON meetings(started_at);
        CREATE TABLE IF NOT EXISTS segments(
          meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          speaker TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS segments_meeting ON segments(meeting_id, start);
        CREATE VIRTUAL TABLE IF NOT EXISTS meeting_text USING fts5(meeting_id UNINDEXED, kind UNINDEXED, text, tokenize='trigram');
        """,
        // 2: notes typed during or after the meeting (F71)
        "ALTER TABLE meetings ADD COLUMN notes TEXT NOT NULL DEFAULT '';",
        // 3: folders (F78), many-to-many; removing a folder or a meeting removes only the link between them
        """
        CREATE TABLE IF NOT EXISTS folders(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS folder_meetings(
          folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
          meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          PRIMARY KEY(folder_id, meeting_id));
        CREATE INDEX IF NOT EXISTS folder_meetings_meeting ON folder_meetings(meeting_id);
        """,
        // 4: when the transcript retention deleted a meeting's segments (F81)
        "ALTER TABLE meetings ADD COLUMN transcript_deleted_at REAL;",
    ]

    public init(path: URL) throws {
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw error("open")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA foreign_keys = ON")  // per connection, and outside a transaction, where it would do nothing
        try migrate()
    }

    private func migrate() throws {
        // The statement is finalized before the migrations run: an open read locks tables a migration may alter.
        let stmt = try prepare("PRAGMA user_version")
        guard sqlite3_step(stmt) == SQLITE_ROW else { sqlite3_finalize(stmt); throw error("user_version") }
        let version = Int(sqlite3_column_int64(stmt, 0))
        sqlite3_finalize(stmt)
        for step in version..<max(version, Self.migrations.count) {
            try transaction {
                try exec(Self.migrations[step])
                try exec("PRAGMA user_version = \(step + 1)")
            }
        }
    }

    deinit { sqlite3_close(db) }

    public func save(_ m: Meeting) throws {
        try transaction {
            // An upsert, not INSERT OR REPLACE: replacing would delete the row and lose its segments and summary.
            let stmt = try prepare("""
                INSERT INTO meetings(\(Self.columns)) VALUES (?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET app = excluded.app, started_at = excluded.started_at,
                  ended_at = excluded.ended_at, me_audio = excluded.me_audio, others_audio = excluded.others_audio
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, m.id)
            bind(stmt, 2, m.app)
            sqlite3_bind_double(stmt, 3, m.startedAt.timeIntervalSince1970)
            if let end = m.endedAt { sqlite3_bind_double(stmt, 4, end.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 4) }
            bind(stmt, 5, m.meAudioPath)
            bind(stmt, 6, m.othersAudioPath)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("save") }
            try index(m.id, "app", [m.app])
        }
    }

    public func append(_ segments: [Segment], to meetingID: String) throws {
        try transaction {
            let stmt = try prepare("INSERT INTO segments(meeting_id, speaker, start, end, text) VALUES (?,?,?,?,?)")
            let fts = try prepare("INSERT INTO meeting_text(meeting_id, kind, text) VALUES (?, 'segment', ?)")
            defer { sqlite3_finalize(stmt); sqlite3_finalize(fts) }
            for s in segments {
                sqlite3_reset(stmt)
                bind(stmt, 1, meetingID)
                bind(stmt, 2, s.speaker.rawValue)
                sqlite3_bind_double(stmt, 3, s.start)
                sqlite3_bind_double(stmt, 4, s.end)
                bind(stmt, 5, s.text)
                // The foreign key fails here for an unknown meeting id.
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("append") }
                sqlite3_reset(fts)
                bind(fts, 1, meetingID)
                bind(fts, 2, s.text)
                guard sqlite3_step(fts) == SQLITE_DONE else { throw error("index") }
            }
        }
    }

    public func remove(_ segments: [Segment], from meetingID: String) throws {
        try transaction {
            let stmt = try prepare("""
                DELETE FROM segments WHERE rowid = (SELECT rowid FROM segments
                  WHERE meeting_id = ? AND speaker = ? AND start = ? AND end = ? AND text = ? LIMIT 1)
                """)
            defer { sqlite3_finalize(stmt) }
            for s in segments {
                sqlite3_reset(stmt)
                bind(stmt, 1, meetingID)
                bind(stmt, 2, s.speaker.rawValue)
                sqlite3_bind_double(stmt, 3, s.start)
                sqlite3_bind_double(stmt, 4, s.end)
                bind(stmt, 5, s.text)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("remove") }
            }
            // The search index has a row per segment: rebuild this meeting's from the segments left.
            for sql in ["DELETE FROM meeting_text WHERE meeting_id = ?1 AND kind = 'segment'",
                        "INSERT INTO meeting_text(meeting_id, kind, text) SELECT meeting_id, 'segment', text FROM segments WHERE meeting_id = ?1"] {
                let s = try prepare(sql)
                defer { sqlite3_finalize(s) }
                bind(s, 1, meetingID)
                guard sqlite3_step(s) == SQLITE_DONE else { throw error("remove") }
            }
        }
    }

    public func setSummary(_ summary: Summary, for meetingID: String) throws {
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        try transaction {
            let stmt = try prepare("UPDATE meetings SET summary = ? WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, json)
            bind(stmt, 2, meetingID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("summary") }
            guard sqlite3_changes(db) == 1 else { throw notFound(meetingID) }
            // The words a person would search for, not the JSON keys.
            let words = [summary.overview] + summary.keyPoints + summary.decisions
                + summary.actionItems.flatMap { [$0.owner, $0.task, $0.due] }
            try index(meetingID, "summary", words)
        }
    }

    public func setNotes(_ notes: String, for meetingID: String) throws {
        try transaction {
            let stmt = try prepare("UPDATE meetings SET notes = ? WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, notes)
            bind(stmt, 2, meetingID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("notes") }
            guard sqlite3_changes(db) == 1 else { throw notFound(meetingID) }
            try index(meetingID, "notes", [notes])
        }
    }

    public func list(limit: Int) throws -> [Meeting] {
        try meetings("SELECT \(Self.columns) FROM meetings ORDER BY started_at DESC LIMIT ?1", limit: limit)
    }

    public func list(inFolder folderID: String, limit: Int) throws -> [Meeting] {
        try meetings("""
            SELECT \(Self.columns) FROM meetings WHERE id IN (SELECT meeting_id FROM folder_meetings WHERE folder_id = ?2)
            ORDER BY started_at DESC LIMIT ?1
            """, limit: limit, query: folderID)
    }

    public func search(_ query: String, folder: String?, limit: Int) throws -> [MeetingHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return try (folder.map { try list(inFolder: $0, limit: limit) } ?? list(limit: limit)).map { MeetingHit(meeting: $0) } }
        let scope = folder == nil ? "" : "WHERE m.id IN (SELECT meeting_id FROM folder_meetings WHERE folder_id = ?3)"
        let cols = Self.columns.split(separator: ",").map { "m." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        // A trigram phrase matches any substring and folds case beyond ASCII, but needs 3 characters: each meeting's
        // best bm25 row gives the snippet (snippet() counts trigrams, so 64 is about 64 characters).
        // ponytail: shorter queries scan with LIKE, which folds ASCII case only, newest first; their snippet is
        // the meeting's first matching text, cut in Swift.
        let short = q.count < 3
        let stmt = try prepare(short ? """
            SELECT \(cols), t.kind, t.text FROM meetings m JOIN meeting_text t ON t.meeting_id = m.id
            \(scope.isEmpty ? "WHERE" : scope + " AND") t.text LIKE ?2 ESCAPE '\\'
            ORDER BY m.started_at DESC, t.kind = 'app', t.rowid
            """ : """
            WITH h AS MATERIALIZED (SELECT meeting_id, kind, snippet(meeting_text, 2, '', '', '…', 64) AS snip,
              bm25(meeting_text) AS score FROM meeting_text WHERE meeting_text MATCH ?2)
            SELECT \(cols), h.kind, h.snip, MIN(h.score) AS best FROM meetings m JOIN h ON h.meeting_id = m.id \(scope)
            GROUP BY m.id ORDER BY best, m.started_at DESC LIMIT ?1
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        bind(stmt, 2, short ? "%" + History.escapeLike(q) + "%" : "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        if let folder { bind(stmt, 3, folder) }
        var hits: [MeetingHit] = [], seen = Set<String>()
        while hits.count < limit, sqlite3_step(stmt) == SQLITE_ROW {
            let m = meeting(stmt)
            guard seen.insert(m.id).inserted else { continue }
            let found = text(stmt, 7)
            hits.append(MeetingHit(meeting: m, snippet: text(stmt, 6) == "app" ? ""
                                   : short ? MeetingHit.snippet(found, around: q) : MeetingHit.words(found, q)))
        }
        return hits
    }

    public func get(_ id: String) throws -> MeetingRecord? {
        let stmt = try prepare("SELECT \(Self.columns), summary, notes, transcript_deleted_at FROM meetings WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var record = MeetingRecord(meeting: meeting(stmt), notes: text(stmt, 7), transcriptDeletedAt: date(stmt, 8))
        if let s = sqlite3_column_text(stmt, 6) {
            record.summary = try JSONDecoder().decode(Summary.self, from: Data(String(cString: s).utf8))
        }
        let segs = try prepare("SELECT speaker, start, end, text FROM segments WHERE meeting_id = ? ORDER BY start, rowid")
        defer { sqlite3_finalize(segs) }
        bind(segs, 1, id)
        while sqlite3_step(segs) == SQLITE_ROW {
            record.segments.append(Segment(speaker: Speaker(rawValue: text(segs, 0)) ?? .others,
                                           start: sqlite3_column_double(segs, 1), end: sqlite3_column_double(segs, 2),
                                           text: text(segs, 3)))
        }
        return record
    }

    public func deleteTranscripts(endedBefore cutoff: Date, recording: String?, now: Date) throws -> [String] {
        var ids: [String] = []
        try transaction {
            // Only meetings with segments: one where nothing was said keeps saying so, not "deleted".
            let find = try prepare("""
                SELECT id FROM meetings WHERE ended_at < ?1 AND transcript_deleted_at IS NULL AND id IS NOT ?2
                  AND id IN (SELECT meeting_id FROM segments) ORDER BY id
                """)
            defer { sqlite3_finalize(find) }
            sqlite3_bind_double(find, 1, cutoff.timeIntervalSince1970)
            if let recording { bind(find, 2, recording) } else { sqlite3_bind_null(find, 2) }
            while sqlite3_step(find) == SQLITE_ROW { ids.append(text(find, 0)) }
            for id in ids {
                for sql in ["DELETE FROM segments WHERE meeting_id = ?1",
                            "DELETE FROM meeting_text WHERE meeting_id = ?1 AND kind = 'segment'",
                            "UPDATE meetings SET transcript_deleted_at = ?2 WHERE id = ?1"] {
                    let stmt = try prepare(sql)
                    defer { sqlite3_finalize(stmt) }
                    bind(stmt, 1, id)
                    if sql.contains("?2") { sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970) }
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("delete transcript") }
                }
            }
        }
        return ids
    }

    // MARK: - Folders (F78)

    public func folders() throws -> [MeetingFolder] {
        var byID: [String: MeetingFolder] = [:]
        let stmt = try prepare("SELECT id, name, created_at FROM folders")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(stmt, 0)
            byID[id] = MeetingFolder(id: id, name: text(stmt, 1), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)))
        }
        let links = try prepare("SELECT folder_id, meeting_id FROM folder_meetings")
        defer { sqlite3_finalize(links) }
        while sqlite3_step(links) == SQLITE_ROW { byID[text(links, 0)]?.meetingIDs.insert(text(links, 1)) }
        return Array(byID.values).byName
    }

    public func createFolder(_ name: String) throws -> MeetingFolder {
        let folder = MeetingFolder(id: UUID().uuidString, name: try MeetingFolder.clean(name), createdAt: Date())
        let stmt = try prepare("INSERT INTO folders(id, name, created_at) VALUES (?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, folder.id)
        bind(stmt, 2, folder.name)
        sqlite3_bind_double(stmt, 3, folder.createdAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("create folder") }
        return folder
    }

    public func renameFolder(_ id: String, to name: String) throws {
        let stmt = try prepare("UPDATE folders SET name = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, try MeetingFolder.clean(name))
        bind(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("rename folder") }
        guard sqlite3_changes(db) == 1 else { throw notFound(id) }
    }

    public func deleteFolder(_ id: String) throws {
        // Its links go with it (ON DELETE CASCADE); its meetings stay.
        let stmt = try prepare("DELETE FROM folders WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("delete folder") }
    }

    public func setFolders(_ folderIDs: Set<String>, for meetingID: String) throws {
        try transaction {
            let del = try prepare("DELETE FROM folder_meetings WHERE meeting_id = ?")
            defer { sqlite3_finalize(del) }
            bind(del, 1, meetingID)
            guard sqlite3_step(del) == SQLITE_DONE else { throw error("folders") }
            let ins = try prepare("INSERT INTO folder_meetings(folder_id, meeting_id) VALUES (?,?)")
            defer { sqlite3_finalize(ins) }
            for f in folderIDs.sorted() {
                sqlite3_reset(ins)
                bind(ins, 1, f)
                bind(ins, 2, meetingID)
                // The foreign keys fail here for an unknown folder or meeting.
                guard sqlite3_step(ins) == SQLITE_DONE else { throw error("folders") }
            }
        }
    }

    public func delete(_ id: String) throws {
        try transaction {
            // Segments and folder links go with the meeting (ON DELETE CASCADE); the search index has no foreign key.
            for sql in ["DELETE FROM meeting_text WHERE meeting_id = ?", "DELETE FROM meetings WHERE id = ?"] {
                let stmt = try prepare(sql)
                defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, id)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("delete") }
            }
        }
    }

    // MARK: - SQLite

    private func index(_ id: String, _ kind: String, _ texts: [String]) throws {
        let del = try prepare("DELETE FROM meeting_text WHERE meeting_id = ? AND kind = ?")
        defer { sqlite3_finalize(del) }
        bind(del, 1, id)
        bind(del, 2, kind)
        guard sqlite3_step(del) == SQLITE_DONE else { throw error("index") }
        let ins = try prepare("INSERT INTO meeting_text(meeting_id, kind, text) VALUES (?,?,?)")
        defer { sqlite3_finalize(ins) }
        bind(ins, 1, id)
        bind(ins, 2, kind)
        bind(ins, 3, texts.filter { !$0.isEmpty }.joined(separator: "\n"))
        guard sqlite3_step(ins) == SQLITE_DONE else { throw error("index") }
    }

    private func meetings(_ sql: String, limit: Int, query: String? = nil) throws -> [Meeting] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        if let query { bind(stmt, 2, query) }
        var rows: [Meeting] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(meeting(stmt)) }
        return rows
    }

    private func meeting(_ stmt: OpaquePointer?) -> Meeting {
        Meeting(id: text(stmt, 0), app: text(stmt, 1), startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                endedAt: date(stmt, 3),
                meAudioPath: text(stmt, 4), othersAudioPath: text(stmt, 5))
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }

    private func date(_ stmt: OpaquePointer?, _ i: Int32) -> Date? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
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

    private func notFound(_ id: String) -> NSError {
        NSError(domain: "MeetingStore", code: 0, userInfo: [NSLocalizedDescriptionKey: "no meeting \(id)"])
    }

    private func error(_ op: String) -> NSError {
        NSError(domain: "MeetingStore", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: "\(op): \(String(cString: sqlite3_errmsg(db)))"])
    }
}

public extension MeetingStoring {
    /// Meeting audio follows the dictation retention: with `.delete24h`, the folder under `dir` (both WAVs) of a
    /// meeting whose recording ended more than 24 h ago is deleted. As with dictation, only the audio goes: the row,
    /// transcript, summary and search entries stay. `recording`, the meeting being recorded, is never touched.
    /// A meeting without an end time (the app crashed while it recorded) and a folder without a row count as ended
    /// when their files were last written. Returns the ids whose folders were deleted.
    @discardableResult
    func applyRetention(_ retention: Retention, dir: URL, recording: String?, now: Date = Date()) throws -> [String] {
        guard retention == .delete24h else { return [] }
        let fm = FileManager.default
        var endedAt: [String: Date] = [:]
        for m in try list(limit: Int.max) { endedAt[m.id] = m.endedAt }
        let cutoff = now.addingTimeInterval(-24 * 3600)
        var deleted: [String] = []
        // Folders come only from the listing, so a stored id never names a path that gets deleted.
        for url in fm.fileExists(atPath: dir.path) ? try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) : []
        where (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            let id = url.lastPathComponent
            guard id != recording, (endedAt[id] ?? lastWritten(url) ?? now) <= cutoff else { continue }
            try fm.removeItem(at: url)
            deleted.append(id)
        }
        return deleted.sorted()
    }
}

/// The newest modification time of `folder` and the files in it.
private func lastWritten(_ folder: URL) -> Date? {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return ([folder] + files).compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
}
