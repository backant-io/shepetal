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
}
