import SQLite3
import XCTest
@testable import ShepetalCore

final class MeetingStoreTests: XCTestCase {
    var root: URL!
    var dbURL: URL { root.appendingPathComponent("meetings.sqlite") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-meetings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func meeting(_ id: String, at t: Double = 1_000, app: String = "Zoom") -> Meeting {
        Meeting(id: id, app: app, startedAt: Date(timeIntervalSince1970: t),
                meAudioPath: "/m/\(id)/Me.wav", othersAudioPath: "/m/\(id)/Others.wav")
    }

    // The recorder saves the meeting at start and again at the end to set endedAt. That second save must not
    // lose the transcript and summary written in between.
    func testSavingAgainKeepsSegmentsAndSummary() throws {
        let store = try MeetingStore(path: dbURL)
        var m = meeting("a")
        try store.save(m)
        XCTAssertNil(try store.get("a")?.meeting.endedAt)
        try store.append([Segment(speaker: .me, start: 1, end: 2, text: "hello")], to: "a")
        let summary = Summary(overview: "o", keyPoints: ["k"], decisions: ["d"], actionItems: [ActionItem(owner: "Me", task: "t", due: "Friday")])
        try store.setSummary(summary, for: "a")
        m.endedAt = Date(timeIntervalSince1970: 2_000)
        try store.save(m)
        let r = try XCTUnwrap(try MeetingStore(path: dbURL).get("a"))  // a new connection: it is on disk
        XCTAssertEqual(r.meeting, m)
        XCTAssertEqual(r.segments, [Segment(speaker: .me, start: 1, end: 2, text: "hello")])
        XCTAssertEqual(r.summary, summary)
    }

    // Live passes store Me and Others separately; the transcript reads in time order.
    func testSegmentsComeBackInTimeOrder() throws {
        let store = try MeetingStore(path: dbURL)
        try store.save(meeting("a"))
        try store.append([Segment(speaker: .me, start: 0, end: 3, text: "one"), Segment(speaker: .me, start: 10, end: 12, text: "three")], to: "a")
        try store.append([Segment(speaker: .others, start: 5, end: 7, text: "two")], to: "a")
        XCTAssertEqual(try store.get("a")?.segments.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(try store.get("a")?.segments.map(\.speaker), [.me, .others, .me])
        XCTAssertNil(try store.get("a")?.summary)
        XCTAssertNil(try store.get("missing"))
    }

    func testSegmentsOrSummaryForAnUnknownMeetingThrow() throws {
        let store = try MeetingStore(path: dbURL)
        XCTAssertThrowsError(try store.append([Segment(speaker: .me, start: 0, end: 1, text: "x")], to: "nope"))
        XCTAssertThrowsError(try store.setSummary(Summary(overview: "x"), for: "nope"))
        XCTAssertTrue(try store.search("x", limit: 10).isEmpty)
    }

    func testListIsNewestFirstAndLimited() throws {
        let store = try MeetingStore(path: dbURL)
        for (id, t) in [("old", 1.0), ("new", 3.0), ("mid", 2.0)] { try store.save(meeting(id, at: t)) }
        XCTAssertEqual(try store.list(limit: 10).map(\.id), ["new", "mid", "old"])
        XCTAssertEqual(try store.list(limit: 2).map(\.id), ["new", "mid"])
    }

    // Search finds a meeting by what was said, by its summary and by its app, in any case, and not by the
    // JSON keys the summary is stored with.
    func testSearchMatchesTranscriptSummaryAndAppInAnyCase() throws {
        let store = try MeetingStore(path: dbURL)
        try store.save(meeting("talk", at: 1, app: "Zoom"))
        try store.save(meeting("sum", at: 2, app: "Google Meet (Chrome)"))
        try store.save(meeting("none", at: 3, app: "Teams"))
        try store.append([Segment(speaker: .others, start: 0, end: 1, text: "Die Größe des Budgets für März")], to: "talk")
        try store.setSummary(Summary(overview: "Launch plan", actionItems: [ActionItem(owner: "Others", task: "book the room")]), for: "sum")
        try store.setSummary(Summary(overview: "Nothing here"), for: "none")

        XCTAssertEqual(try store.search("BUDGETS", limit: 10).map(\.id), ["talk"])
        XCTAssertEqual(try store.search("GRÖSSE".lowercased(), limit: 10).map(\.id), [])  // ss is not ß
        XCTAssertEqual(try store.search("GRÖßE", limit: 10).map(\.id), ["talk"])          // ö folds beyond ASCII
        XCTAssertEqual(try store.search("udge", limit: 10).map(\.id), ["talk"])           // inside a word
        XCTAssertEqual(try store.search("Book The", limit: 10).map(\.id), ["sum"])
        XCTAssertEqual(try store.search("google meet", limit: 10).map(\.id), ["sum"])
        XCTAssertEqual(try store.search("owner", limit: 10).map(\.id), [])
        XCTAssertEqual(try store.search("overview", limit: 10).map(\.id), [])
        XCTAssertEqual(try store.search("an", limit: 10).map(\.id), ["sum"])  // short: "Launch plan"
        XCTAssertEqual(try store.search("", limit: 10).map(\.id), ["none", "sum", "talk"])
        XCTAssertEqual(try store.search("\"", limit: 10).map(\.id), [])
        XCTAssertEqual(try store.search("a \"b", limit: 10).map(\.id), [])
        XCTAssertEqual(try store.search("%", limit: 10).map(\.id), [])

        // A new summary replaces the old one in the index.
        try store.setSummary(Summary(overview: "Retro"), for: "sum")
        XCTAssertEqual(try store.search("book the", limit: 10).map(\.id), [])
        XCTAssertEqual(try store.search("retro", limit: 10).map(\.id), ["sum"])
        // So does a renamed app.
        try store.save(meeting("sum", at: 2, app: "Slack"))
        XCTAssertEqual(try store.search("google", limit: 10).map(\.id), [])
        XCTAssertEqual(try store.search("slack", limit: 10).map(\.id), ["sum"])
    }

    // Every meetings.sqlite written before notes (no user_version) must open with its meetings, transcripts,
    // summaries and search intact, take notes, and keep opening on every later launch.
    func testOldMeetingsFileUpgradesWithoutLosingRows() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        // The schema as shipped in #113, with what a recorded meeting left in it.
        XCTAssertEqual(sqlite3_exec(db, """
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS meetings(
              id TEXT PRIMARY KEY, app TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL,
              me_audio TEXT NOT NULL, others_audio TEXT NOT NULL, summary TEXT);
            CREATE INDEX IF NOT EXISTS meetings_started ON meetings(started_at);
            CREATE TABLE IF NOT EXISTS segments(
              meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              speaker TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS segments_meeting ON segments(meeting_id, start);
            CREATE VIRTUAL TABLE IF NOT EXISTS meeting_text USING fts5(meeting_id UNINDEXED, kind UNINDEXED, text, tokenize='trigram');
            INSERT INTO meetings VALUES ('a', 'Zoom', 1000, 2000, '/m/a/Me.wav', '/m/a/Others.wav',
              '{"overview":"Budget call","keyPoints":[],"decisions":[],"actionItems":[]}');
            INSERT INTO segments VALUES ('a', 'Me', 1, 2, 'the budget is fine');
            INSERT INTO meeting_text VALUES ('a', 'app', 'Zoom'), ('a', 'segment', 'the budget is fine'), ('a', 'summary', 'Budget call');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let m = Meeting(id: "a", app: "Zoom", startedAt: Date(timeIntervalSince1970: 1000), endedAt: Date(timeIntervalSince1970: 2000),
                        meAudioPath: "/m/a/Me.wav", othersAudioPath: "/m/a/Others.wav")
        let old = MeetingRecord(meeting: m, segments: [Segment(speaker: .me, start: 1, end: 2, text: "the budget is fine")],
                                summary: Summary(overview: "Budget call"))
        let store = try MeetingStore(path: dbURL)
        XCTAssertEqual(try store.get("a"), old, "first open migrates and keeps the row, with no notes")
        XCTAssertEqual(try store.search("budget", limit: 10).map(\.id), ["a"])
        try store.setNotes("ask about Q3", for: "a")
        var noted = old
        noted.notes = "ask about Q3"
        XCTAssertEqual(try MeetingStore(path: dbURL).get("a"), noted, "second open must not migrate again")
    }

    // Notes are typed while the meeting records, so the save that ends it must keep them; they are found by search
    // like the transcript, a rewrite replaces them in the index, and they go when the meeting is deleted.
    func testNotesSurviveTheEndOfTheMeetingAreSearchableAndGoWithIt() throws {
        let store = try MeetingStore(path: dbURL)
        var m = meeting("a")
        try store.save(m)
        XCTAssertEqual(try store.get("a")?.notes, "")
        try store.setNotes("- Ask Kate about the Größe\n- TODO: book room", for: "a")
        m.endedAt = Date(timeIntervalSince1970: 2_000)
        try store.save(m)
        try store.setSummary(Summary(overview: "o"), for: "a")
        XCTAssertEqual(try MeetingStore(path: dbURL).get("a")?.notes, "- Ask Kate about the Größe\n- TODO: book room")
        XCTAssertEqual(try store.search("GRÖßE", limit: 10).map(\.id), ["a"])
        XCTAssertEqual(try store.search("book room", limit: 10).map(\.id), ["a"])

        try store.setNotes("call Leo", for: "a")
        XCTAssertEqual(try store.search("kate", limit: 10).map(\.id), [], "the old notes leave the index")
        XCTAssertEqual(try store.search("leo", limit: 10).map(\.id), ["a"])
        XCTAssertThrowsError(try store.setNotes("x", for: "nope"))

        try store.delete("a")
        XCTAssertNil(try store.get("a"))
        // The index has no foreign key: a row left behind would keep the notes' text in the file.
        var db: OpaquePointer?, stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM meeting_text WHERE text LIKE '%Leo%'", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0, "nothing of the notes is left in the index")
    }

    // Rule 4: what was said in a meeting is as private as its audio.
    func testFileIsOwnerOnly() throws {
        _ = try MeetingStore(path: dbURL)
        let mode = try FileManager.default.attributesOfItem(atPath: dbURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    // Meeting audio follows the dictation retention (Pavel's decision 2). With delete after 24 h, the audio folder
    // of a meeting whose recording ended more than 24 h ago is deleted. Only the audio: as with dictation history,
    // the row, transcript, summary and search entries stay, because the setting runs at once when it is picked and
    // nothing asks first. A newer meeting keeps its audio, and so does the meeting being recorded, however old its
    // files look. A meeting cut off by a crash (no end time) and a folder with no row count as ended when their
    // audio was last written.
    func testRetentionDeletesOnlyTheAudioOfMeetingsEndedOver24hAgoButNeverOfTheOneRecording() throws {
        let store = try MeetingStore(path: dbURL)
        let fm = FileManager.default
        let dir = root.appendingPathComponent("meetings")
        let now = Date(timeIntervalSince1970: 10_000_000)
        let day = 24.0 * 3600
        func age(_ url: URL, _ ago: Double) throws {
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-ago)], ofItemAtPath: url.path)
        }
        func add(_ id: String, endedAgo: Double?, writtenAgo: Double, row: Bool = true) throws {
            let folder = dir.appendingPathComponent(id)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = ["Me.wav", "Others.wav"].map { folder.appendingPathComponent($0) }
            for f in files { try Data([1]).write(to: f); try age(f, writtenAgo) }
            try age(folder, writtenAgo)
            guard row else { return }
            try store.save(Meeting(id: id, app: "Zoom", startedAt: now.addingTimeInterval(-writtenAgo - 3600),
                                   endedAt: endedAgo.map { now.addingTimeInterval(-$0) },
                                   meAudioPath: files[0].path, othersAudioPath: files[1].path))
            try store.append([Segment(speaker: .me, start: 0, end: 1, text: "budget \(id)")], to: id)
            try store.setSummary(Summary(overview: "summary \(id)"), for: id)
        }
        try add("old", endedAgo: day + 1, writtenAgo: day + 1)
        try add("fresh", endedAgo: day - 60, writtenAgo: day - 60)
        try add("recording", endedAgo: nil, writtenAgo: 3 * day)  // old files, so only its id keeps it
        try add("crashed", endedAgo: nil, writtenAgo: day + 1)
        try add("crashed-recently", endedAgo: nil, writtenAgo: 60)
        try add("no-row", endedAgo: nil, writtenAgo: day + 1, row: false)
        // A stored id is never used as a path: this row must not take the dictation audio with it.
        let audio = root.appendingPathComponent("audio")
        try fm.createDirectory(at: audio, withIntermediateDirectories: true)
        try store.save(Meeting(id: "../audio", app: "Zoom", startedAt: now.addingTimeInterval(-3 * day),
                               endedAt: now.addingTimeInterval(-2 * day), meAudioPath: "", othersAudioPath: ""))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))

        XCTAssertEqual(try store.applyRetention(.keep, dir: dir, recording: nil, now: now.addingTimeInterval(365 * day)), [])
        XCTAssertEqual(try store.list(limit: 10).count, 6)

        XCTAssertEqual(try store.applyRetention(.delete24h, dir: dir, recording: "recording", now: now),
                       ["crashed", "no-row", "old"])
        XCTAssertEqual(try store.list(limit: 10).count, 6, "every meeting stays listed")
        for gone in ["old", "crashed", "no-row"] {
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(gone).path), gone)
        }
        for kept in ["fresh", "recording", "crashed-recently"] {
            XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(kept).appendingPathComponent("Me.wav").path), kept)
        }
        XCTAssertTrue(fm.fileExists(atPath: audio.path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(".DS_Store").path))
        for id in ["old", "crashed"] {
            let kept = try XCTUnwrap(try store.get(id), id)
            XCTAssertEqual(kept.segments.map(\.text), ["budget \(id)"], "the transcript stays")
            XCTAssertEqual(kept.summary?.overview, "summary \(id)", "the summary stays")
            XCTAssertTrue(try store.search("budget \(id)", limit: 10).map(\.id).contains(id), "it is still found")
        }
        XCTAssertEqual(try store.search("budget", limit: 10).count, 5)

        // A minute later the fresh one is past 24 h as well; the recording one is still kept.
        XCTAssertEqual(try store.applyRetention(.delete24h, dir: dir, recording: "recording", now: now.addingTimeInterval(61)), ["fresh"])
        // Once it is no longer recording (the app crashed during it), its old files let it go.
        XCTAssertEqual(try store.applyRetention(.delete24h, dir: dir, recording: nil, now: now.addingTimeInterval(61)), ["recording"])
        XCTAssertEqual(try store.list(limit: 10).count, 6, "no sweep deletes a meeting itself")
    }

    // No meeting was ever recorded: the sweep has nothing to do and does not fail.
    func testRetentionWithoutAMeetingsFolderDeletesNothing() throws {
        let store = try MeetingStore(path: dbURL)
        XCTAssertEqual(try store.applyRetention(.delete24h, dir: root.appendingPathComponent("meetings"), recording: nil), [])
    }

    // MARK: - F81 transcript retention

    /// Rows left in the search index for the meeting, by kind.
    func indexed(_ id: String, kind: String) throws -> Int32 {
        var db: OpaquePointer?, stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM meeting_text WHERE meeting_id = '\(id)' AND kind = '\(kind)'", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return sqlite3_column_int(stmt, 0)
    }

    // "Delete after N days" removes what was said in meetings that ended more than N days ago, and nothing else:
    // the summary, the notes, the folders and the audio paths stay (rule 4 keeps the audio on its own setting),
    // search stops finding the words, and the pane can say when it happened. A meeting still recording (no end), the
    // one the app says is recording, a newer one and one where nothing was said are left as they are. Keep deletes
    // nothing, and a second sweep changes nothing, so the hourly timer is safe.
    func testTranscriptRetentionDeletesOnlyTheTranscriptsOfMeetingsEndedBeforeTheCutoff() throws {
        let store = try MeetingStore(path: dbURL)
        let now = Date(timeIntervalSince1970: 10_000_000)
        let day = 86_400.0
        func add(_ id: String, endedAgo: Double?, said: Bool = true) throws {
            try store.save(Meeting(id: id, app: "Zoom", startedAt: now.addingTimeInterval(-(endedAgo ?? 0) - 3_600),
                                   endedAt: endedAgo.map { now.addingTimeInterval(-$0) },
                                   meAudioPath: "/m/\(id)/Me.wav", othersAudioPath: "/m/\(id)/Others.wav"))
            if said { try store.append([Segment(speaker: .me, start: 0, end: 1, text: "budget talk \(id)")], to: id) }
            try store.setSummary(Summary(overview: "summary \(id)"), for: id)
            try store.setNotes("note \(id)", for: id)
        }
        try add("old", endedAgo: 2 * day)
        try add("fresh", endedAgo: day - 60)
        try add("running", endedAgo: nil)
        try add("guarded", endedAgo: 3 * day)
        try add("silent", endedAgo: 5 * day, said: false)
        let work = try store.createFolder("Work")
        try store.setFolders([work.id], for: "old")
        let before = try XCTUnwrap(try store.get("old"))

        XCTAssertEqual(try store.applyTranscriptRetention(days: 0, recording: nil, now: now.addingTimeInterval(400 * day)), [], "keep")
        XCTAssertEqual(try store.get("old")?.segments.count, 1)

        XCTAssertEqual(try store.applyTranscriptRetention(days: 1, recording: "guarded", now: now), ["old"])
        let old = try XCTUnwrap(try MeetingStore(path: dbURL).get("old"))  // on disk
        XCTAssertEqual(old.segments, [], "the transcript is gone")
        XCTAssertEqual(old.transcriptDeletedAt, now)
        XCTAssertEqual(old.meeting, before.meeting, "the row and its audio paths stay")
        XCTAssertEqual(old.summary, before.summary)
        XCTAssertEqual(old.notes, "note old")
        XCTAssertEqual(try store.folders().first?.meetingIDs, ["old"], "it stays in its folder")
        XCTAssertEqual(try store.search("budget talk old", limit: 10).map(\.id), [], "search no longer finds the words")
        XCTAssertEqual(try indexed("old", kind: "segment"), 0, "nothing of the transcript is left in the index")
        XCTAssertEqual(try store.search("summary old", limit: 10).map(\.id), ["old"], "the summary is still found")
        XCTAssertEqual(try store.search("note old", limit: 10).map(\.id), ["old"])
        for kept in ["fresh", "running", "guarded"] {
            XCTAssertEqual(try store.get(kept)?.segments.map(\.text), ["budget talk \(kept)"], kept)
            XCTAssertNil(try store.get(kept)?.transcriptDeletedAt, kept)
        }
        XCTAssertNil(try store.get("silent")?.transcriptDeletedAt, "nothing was said, so nothing was deleted")

        // The next sweep, before "fresh" is a day old: nothing new to delete, and the deletion keeps its first date.
        XCTAssertEqual(try store.applyTranscriptRetention(days: 1, recording: "guarded", now: now.addingTimeInterval(30)), [])
        XCTAssertEqual(try store.get("old")?.transcriptDeletedAt, now)
        // Once it is no longer the recording one, the guarded meeting follows the setting too; the running one never does.
        XCTAssertEqual(try store.applyTranscriptRetention(days: 1, recording: nil, now: now.addingTimeInterval(61)), ["fresh", "guarded"])
        XCTAssertEqual(try store.get("running")?.segments.count, 1)
        XCTAssertEqual(try store.list(limit: 10).count, 5, "no meeting is deleted")
    }

    // A meetings.sqlite from the notes build (user_version 2, no folders, no transcript column) opens with its rows,
    // gets folders and the transcript retention, and opens again without migrating twice.
    func testFileFromTheNotesBuildUpgradesToFoldersAndTranscriptRetention() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        for step in MeetingStore.migrations.prefix(2) { XCTAssertEqual(sqlite3_exec(db, step, nil, nil, nil), SQLITE_OK) }
        XCTAssertEqual(sqlite3_exec(db, """
            PRAGMA user_version = 2;
            INSERT INTO meetings(id, app, started_at, ended_at, me_audio, others_audio, summary, notes)
              VALUES ('a', 'Zoom', 1000, 2000, '/m/a/Me.wav', '/m/a/Others.wav', NULL, 'ask about Q3');
            INSERT INTO segments VALUES ('a', 'Me', 1, 2, 'the budget is fine');
            INSERT INTO meeting_text VALUES ('a', 'app', 'Zoom'), ('a', 'segment', 'the budget is fine'), ('a', 'notes', 'ask about Q3');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try MeetingStore(path: dbURL)
        let r = try XCTUnwrap(try store.get("a"))
        XCTAssertEqual(r.segments.map(\.text), ["the budget is fine"])
        XCTAssertEqual(r.notes, "ask about Q3")
        XCTAssertNil(r.transcriptDeletedAt)
        XCTAssertEqual(try store.folders(), [])
        let f = try store.createFolder("Budget")
        try store.setFolders([f.id], for: "a")
        XCTAssertEqual(try MeetingStore(path: dbURL).list(inFolder: f.id, limit: 10).map(\.id), ["a"], "second open keeps the folder")
        XCTAssertEqual(try store.applyTranscriptRetention(days: 1, recording: nil, now: Date(timeIntervalSince1970: 2000 + 86_401)), ["a"])
        XCTAssertEqual(try store.search("budget", limit: 10).map(\.id), [], "the folder name is not searched, the transcript is gone")
    }

    // MARK: - F78 folders

    // Folders are a join table, as in Wispr Flow: one meeting can be in two folders, and deleting a folder or a
    // meeting removes only the link, never the other side. Names are trimmed and never empty.
    func testFoldersHoldMeetingsWithoutOwningThem() throws {
        let store = try MeetingStore(path: dbURL)
        for (id, t) in [("a", 1.0), ("b", 2.0), ("c", 3.0)] { try store.save(meeting(id, at: t)) }
        try store.append([Segment(speaker: .others, start: 0, end: 1, text: "quarterly budget")], to: "a")
        let work = try store.createFolder("  Work ")
        let clients = try store.createFolder("clients")
        XCTAssertEqual(work.name, "Work")
        XCTAssertThrowsError(try store.createFolder("   "))
        XCTAssertEqual(try store.folders().map(\.name), ["clients", "Work"], "by name, in any case")

        try store.setFolders([work.id, clients.id], for: "a")
        try store.setFolders([work.id], for: "c")
        XCTAssertEqual(try store.list(inFolder: work.id, limit: 10).map(\.id), ["c", "a"], "newest first")
        XCTAssertEqual(try store.list(inFolder: work.id, limit: 1).map(\.id), ["c"])
        XCTAssertEqual(try store.list(inFolder: clients.id, limit: 10).map(\.id), ["a"], "a is in two folders")
        XCTAssertEqual(try store.folders().first { $0.id == work.id }?.meetingIDs, ["a", "c"])
        XCTAssertThrowsError(try store.setFolders([work.id, "nope"], for: "b"))
        XCTAssertEqual(try store.list(inFolder: work.id, limit: 10).map(\.id), ["c", "a"], "a failed change changes nothing")
        XCTAssertThrowsError(try store.setFolders([work.id], for: "nope"))

        try store.renameFolder(clients.id, to: "Acme")
        XCTAssertEqual(try MeetingStore(path: dbURL).folders().map(\.name), ["Acme", "Work"])
        XCTAssertThrowsError(try store.renameFolder(clients.id, to: ""))
        XCTAssertThrowsError(try store.renameFolder("nope", to: "x"))

        try store.deleteFolder(work.id)
        XCTAssertEqual(try store.list(limit: 10).map(\.id), ["c", "b", "a"], "its meetings stay")
        XCTAssertEqual(try store.search("budget", limit: 10).map(\.id), ["a"], "and so do their search entries")
        XCTAssertEqual(try store.folders().map(\.meetingIDs), [["a"]], "and their other folders")
        XCTAssertEqual(try store.list(inFolder: work.id, limit: 10), [])

        try store.delete("a")
        XCTAssertEqual(try store.folders().map(\.meetingIDs), [[]])
        var db: OpaquePointer?, stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM folder_meetings", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0, "a deleted meeting leaves no folder rows")
    }

    // MARK: - F120 search results

    // A result shows where it matched: the words around the match, cut at word edges with "…", on one line. The
    // app name is the row's title already, so a match on it alone shows no snippet.
    func testSearchSnippetHoldsTheMatchWithItsContext() throws {
        let store = try MeetingStore(path: dbURL)
        try store.save(meeting("a"))
        try store.append([Segment(speaker: .others, start: 0, end: 1, text: """
            We talked for a long time about many unrelated things and then the quarterly budget for marketing came up, \
            which nobody liked at all, really.
            """)], to: "a")
        try store.save(meeting("z", at: 2, app: "Budgetly"))
        let hits = try store.search("BUDGET", folder: nil, limit: 10)
        XCTAssertEqual(Set(hits.map(\.meeting.id)), ["a", "z"])
        let snippet = try XCTUnwrap(hits.first { $0.meeting.id == "a" }?.snippet)
        XCTAssertTrue(snippet.contains("the quarterly budget for marketing"), snippet)
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…"), snippet)
        XCTAssertLessThanOrEqual(snippet.count, 66, snippet)
        let words = snippet.trimmingCharacters(in: CharacterSet(charactersIn: "…")).split(separator: " ")
        let all = Set("We talked for a long time about many unrelated things and then the quarterly budget for marketing came up, which nobody liked at all, really.".split(separator: " "))
        XCTAssertTrue(words.allSatisfy(all.contains), "no half words: \(snippet)")
        XCTAssertEqual(hits.first { $0.meeting.id == "z" }?.snippet, "", "the app name alone")

        try store.setNotes("first line\nask Kate about the budget\nlast", for: "z")
        XCTAssertEqual(try store.search("kate", folder: nil, limit: 10).map(\.snippet), ["first line ask Kate about the budget last"])
        XCTAssertEqual(try store.search("", folder: nil, limit: 10).map(\.snippet), ["", ""], "no query, no snippet")
    }

    // Best match first (bm25), then the newest: a meeting whose summary is about the budget beats a newer one that
    // mentioned it once in a long sentence, and equal matches are newest first.
    func testSearchRanksBestMatchFirstThenNewest() throws {
        let store = try MeetingStore(path: dbURL)
        for (id, t) in [("summary", 1.0), ("passing", 5.0), ("twin-old", 2.0), ("twin-new", 3.0)] { try store.save(meeting(id, at: t, app: "Call")) }
        try store.setSummary(Summary(overview: "Budget review"), for: "summary")
        try store.append([Segment(speaker: .me, start: 0, end: 1, text: """
            After lunch we went through the roadmap, hiring, the office move and then briefly the budget before we stopped.
            """)], to: "passing")
        for id in ["twin-old", "twin-new"] {
            try store.append([Segment(speaker: .me, start: 0, end: 1, text: "We discussed a budget for the launch party and the venue")], to: id)
        }
        XCTAssertEqual(try store.search("budget", limit: 10).map(\.id), ["summary", "twin-new", "twin-old", "passing"])
        XCTAssertEqual(try store.search("budget", limit: 2).map(\.id), ["summary", "twin-new"])
    }

    // In the Folders tab the search looks only in the open folder; with no query it lists that folder.
    func testSearchInsideAFolder() throws {
        let store = try MeetingStore(path: dbURL)
        for (id, t) in [("in", 1.0), ("out", 2.0), ("in-too", 3.0)] {
            try store.save(meeting(id, at: t))
            try store.append([Segment(speaker: .me, start: 0, end: 1, text: "budget talk")], to: id)
        }
        try store.setNotes("only said outside", for: "out")
        let f = try store.createFolder("Budget")
        try store.setFolders([f.id], for: "in")
        try store.setFolders([f.id], for: "in-too")
        XCTAssertEqual(try store.search("budget", folder: f.id, limit: 10).map(\.meeting.id), ["in-too", "in"], "same text, newest first")
        XCTAssertEqual(try store.search("said outside", folder: f.id, limit: 10), [])
        XCTAssertEqual(try store.search("said outside", folder: nil, limit: 10).map(\.meeting.id), ["out"], "found in All")
        XCTAssertEqual(try store.search("", folder: f.id, limit: 10).map(\.meeting.id), ["in-too", "in"])
        XCTAssertEqual(try store.search("ta", folder: f.id, limit: 10).map(\.meeting.id), ["in-too", "in"], "short query")
        XCTAssertEqual(try store.search("budget", folder: "nope", limit: 10), [])
        XCTAssertEqual(try store.search("budget", folder: nil, limit: 10).count, 3)
    }

    // Under 3 characters the trigram index cannot match: the LIKE scan stays, newest first, and its snippet is
    // the text around the first match, taken from what was said or written before the app name.
    func testShortQueryKeepsTheSubstringPathWithASnippet() throws {
        let store = try MeetingStore(path: dbURL)
        try store.save(meeting("old", at: 1, app: "Q3 sync"))
        try store.save(meeting("new", at: 2, app: "Zoom"))
        try store.setSummary(Summary(overview: "Plans for Q3 and the hiring that has to happen before the end of the year, if the budget allows it"), for: "new")
        let hits = try store.search("q3", folder: nil, limit: 10)
        XCTAssertEqual(hits.map(\.meeting.id), ["new", "old"])
        XCTAssertEqual(hits.map(\.snippet), ["Plans for Q3 and the hiring that has to happen before the end of…", ""])
        // A cut inside a word moves back to the space before it.
        XCTAssertEqual(MeetingHit.snippet("so the budgeting of Q3 went fine", around: "q3", width: 14), "…of Q3 went…")
        try store.setNotes("Q3", for: "old")
        XCTAssertEqual(try store.search("q3", folder: nil, limit: 10).map(\.snippet).last, "Q3", "the notes before the app name")
        XCTAssertEqual(try store.search("q3", folder: nil, limit: 1).map(\.meeting.id), ["new"])
    }
}
