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

    // Rule 4: what was said in a meeting is as private as its audio.
    func testFileIsOwnerOnly() throws {
        _ = try MeetingStore(path: dbURL)
        let mode = try FileManager.default.attributesOfItem(atPath: dbURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    // Meeting audio follows the dictation retention (Pavel's decision). With delete after 24 h, a meeting whose
    // recording ended more than 24 h ago goes whole: folder, row, transcript and search entries. A newer one stays,
    // and the meeting being recorded stays however old its files look. A meeting cut off by a crash (no end time)
    // and a folder with no row count as ended when their audio was last written.
    func testRetentionDeletesMeetingsEndedOver24hAgoButNeverTheOneRecording() throws {
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
                       ["../audio", "crashed", "no-row", "old"])
        XCTAssertEqual(Set(try store.list(limit: 10).map(\.id)), ["fresh", "recording", "crashed-recently"])
        for gone in ["old", "crashed", "no-row"] {
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(gone).path), gone)
        }
        for kept in ["fresh", "recording", "crashed-recently"] {
            XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(kept).appendingPathComponent("Me.wav").path), kept)
        }
        XCTAssertTrue(fm.fileExists(atPath: audio.path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(".DS_Store").path))
        XCTAssertNil(try store.get("old"))
        XCTAssertEqual(try store.search("budget old", limit: 10), [], "its search entries are gone too")
        XCTAssertEqual(try store.search("budget", limit: 10).count, 3)

        // A minute later the fresh one is past 24 h as well; the recording one is still kept.
        XCTAssertEqual(try store.applyRetention(.delete24h, dir: dir, recording: "recording", now: now.addingTimeInterval(61)), ["fresh"])
        // Once it is no longer recording (the app crashed during it), its old files let it go.
        XCTAssertEqual(try store.applyRetention(.delete24h, dir: dir, recording: nil, now: now.addingTimeInterval(61)), ["recording"])
    }

    // No meeting was ever recorded: the sweep has nothing to do and does not fail.
    func testRetentionWithoutAMeetingsFolderDeletesNothing() throws {
        let store = try MeetingStore(path: dbURL)
        XCTAssertEqual(try store.applyRetention(.delete24h, dir: root.appendingPathComponent("meetings"), recording: nil), [])
    }
}
