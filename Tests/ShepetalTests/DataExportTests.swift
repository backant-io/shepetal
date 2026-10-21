import XCTest
import ShepetalCore
@testable import Shepetal

/// F64: "Export my data…" is how a user takes everything shepetal kept with them. What matters: nothing is left out
/// (archived dictations, meetings without a summary), the files stay owner-only like the data dir, the JSON reads
/// back to the same rows (the dictionary import, F117, reads it), the CSV opens right in a spreadsheet, nothing is
/// overwritten, and a failed export leaves no half folder. Temp files only; no panel, clipboard or running app.
final class DataExportTests: XCTestCase {
    private var dir: URL!
    private var out: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_792_508_400)  // 2026-10-20 15:00 UTC
    private var now: Date { t0.addingTimeInterval(86_400) }      // 2026-10-21

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        out = dir.appendingPathComponent("out")
        try AudioStore.makeOwnerOnlyDirectory(out)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private lazy var rows = [
        HistoryEntry(id: "d1", createdAt: t0, outcome: .inserted, audioPath: "/a/d1.wav", durationMs: 2000, model: "some-model",
                     rawText: "um he said hi", text: "He said \"hi\", then\nleft.", app: "Mail", bundleId: "com.apple.mail"),
        HistoryEntry(id: "d2", createdAt: t0.addingTimeInterval(60), outcome: .pasteFailed, audioPath: "/a/d2.wav", durationMs: 1500,
                     text: "Archived one", app: "Safari", bundleId: "com.apple.Safari", url: "https://example.com/page", archived: true,
                     reverted: true),
        HistoryEntry(id: "d3", createdAt: t0.addingTimeInterval(120), outcome: .tooShort, audioPath: "/a/d3.wav", durationMs: 120),
    ]

    private lazy var summarized = MeetingRecord(
        meeting: Meeting(id: "m1", app: "Zoom", startedAt: t0, endedAt: t0.addingTimeInterval(42 * 60),
                         meAudioPath: "/m/m1/Me.wav", othersAudioPath: "/m/m1/Others.wav"),
        segments: [Segment(speaker: .others, start: 4, end: 9, text: "Shall we ship on Friday?"),
                   Segment(speaker: .me, start: 10, end: 12, text: "Yes.")],
        summary: Summary(overview: "Ships Friday.", decisions: ["Ship on Friday"], actionItems: [ActionItem(owner: "Pavel", task: "Send notes")]),
        notes: "TODO: book the venue")
    // Same app and minute as m1, and never summarized.
    private lazy var bare = MeetingRecord(
        meeting: Meeting(id: "m2", app: "Zoom", startedAt: t0.addingTimeInterval(20), endedAt: t0.addingTimeInterval(600),
                         meAudioPath: "/m/m2/Me.wav", othersAudioPath: "/m/m2/Others.wav"),
        segments: [Segment(speaker: .others, start: 1, end: 2, text: "Hello?")])

    private func stores(dictionary: String? = "# comment\n*Kubernetes\ngit hub => GitHub\n") throws -> (History, MeetingStore, URL) {
        let history = try History(path: dir.appendingPathComponent("history.sqlite"))
        for r in rows { try history.add(r) }
        let meetings = try MeetingStore(path: dir.appendingPathComponent("meetings.sqlite"))
        for r in [summarized, bare] {
            try meetings.save(r.meeting)
            try meetings.append(r.segments, to: r.meeting.id)
            if let s = r.summary { try meetings.setSummary(s, for: r.meeting.id) }
            if !r.notes.isEmpty { try meetings.setNotes(r.notes, for: r.meeting.id) }
        }
        let txt = dir.appendingPathComponent("dictionary.txt")
        if let dictionary { try dictionary.write(to: txt, atomically: true, encoding: .utf8) }
        return (history, meetings, txt)
    }

    private func export(_ s: (History, MeetingStore, URL)) throws -> URL {
        try DataExport.write(into: out, history: s.0, meetings: s.1, dictionary: s.2, now: now, timeZone: utc)
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testEveryFileExistsAndIsOwnerOnly() throws {
        let folder = try export(try stores())
        XCTAssertEqual(folder.path, out.appendingPathComponent("shepetal-export-2026-10-21").path)
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertEqual(try mode(folder.appendingPathComponent("meetings")), 0o700)
        let fm = FileManager.default
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["dictionary.json", "dictionary.txt", "history.csv", "history.json", "meetings", "meetings.json"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.appendingPathComponent("meetings").path).sorted(),
                       ["Zoom 2026-10-20 1500 2.md", "Zoom 2026-10-20 1500.md"], "two meetings in one minute keep two files")
        for name in ["dictionary.json", "dictionary.txt", "history.csv", "history.json", "meetings.json",
                     "meetings/Zoom 2026-10-20 1500.md", "meetings/Zoom 2026-10-20 1500 2.md"] {
            XCTAssertEqual(try mode(folder.appendingPathComponent(name)), 0o600, name)
        }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("meetings/Zoom 2026-10-20 1500.md"), encoding: .utf8),
                       MeetingFormat.markdown(summarized, timeZone: utc), "the same Markdown as the Meetings tab's export")
        // Recordings are referenced, not copied.
        XCTAssertFalse(try fm.subpathsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".wav") })
    }

    func testTheJSONDecodesBackToTheSameRows() throws {
        let s = try stores()
        let folder = try export(s)
        let history = try decoder().decode([DataExport.Dictation].self, from: Data(contentsOf: folder.appendingPathComponent("history.json")))
        XCTAssertEqual(history, rows.reversed().map(DataExport.Dictation.init), "every row, newest first, archived and too short too")
        XCTAssertEqual(history.map(\.createdAt), rows.reversed().map(\.createdAt))
        XCTAssertEqual(history[1].url, "https://example.com/page")
        XCTAssertEqual(history[1].outcome, "paste_failed")
        XCTAssertEqual(history.map(\.reverted), [false, true, false], "History's Show raw (F48) is kept")
        let json = try String(contentsOf: folder.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("some-model"), "model names never reach the user")

        let meetings = try decoder().decode([DataExport.MeetingExport].self, from: Data(contentsOf: folder.appendingPathComponent("meetings.json")))
        XCTAssertEqual(meetings, [bare, summarized].map { DataExport.MeetingExport(meeting: $0.meeting, segments: $0.segments, summary: $0.summary, notes: $0.notes) },
                       "newest first, the one without a summary too")
        XCTAssertEqual(meetings[1].notes, "TODO: book the venue", "the meeting's notes (F71) are the user's data too")
        XCTAssertNil(meetings[0].summary)

        let words = try decoder().decode(DataExport.DictionaryFile.self, from: Data(contentsOf: folder.appendingPathComponent("dictionary.json")))
        XCTAssertEqual(words.dictionary, [.init(spoken: "Kubernetes", written: "Kubernetes", starred: true),
                                          .init(spoken: "git hub", written: "GitHub", starred: false)])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("dictionary.txt")), try Data(contentsOf: s.2), "a byte-for-byte copy")
    }

    func testTheCSVQuotesCommasQuotesAndNewlines() throws {
        let folder = try export(try stores())
        let csv = try String(contentsOf: folder.appendingPathComponent("history.csv"), encoding: .utf8)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, #""created","outcome","app","url","text","raw_text","duration_ms","archived","audio_path","id""#)
        XCTAssertEqual(lines.last, "", "every record ends with CRLF")
        XCTAssertTrue(csv.contains("\r\n\"20.10.26 15:00:00\",\"inserted\",\"Mail\",\"\",\"He said \"\"hi\"\", then\nleft.\",\"um he said hi\",\"2000\",\"no\",\"/a/d1.wav\",\"d1\"\r\n"),
                      "a quote is doubled and the comma and newline stay inside the quoted field")
        XCTAssertTrue(csv.contains(#""20.10.26 15:01:00","paste_failed","Safari","https://example.com/page","Archived one","","1500","yes","/a/d2.wav","d2""#))
        XCTAssertEqual(lines.count, 1 + rows.count + 1, "header, three rows (a newline inside a field is not a line end), then the end")
    }

    func testEmptyStoresGiveValidEmptyFiles() throws {
        let history = try History(path: dir.appendingPathComponent("empty-history.sqlite"))
        let folder = try DataExport.write(into: out, history: history, meetings: InMemoryMeetingStore(),
                                          dictionary: dir.appendingPathComponent("missing.txt"), now: now, timeZone: utc)
        XCTAssertEqual(try decoder().decode([DataExport.Dictation].self, from: Data(contentsOf: folder.appendingPathComponent("history.json"))), [])
        XCTAssertEqual(try decoder().decode([DataExport.MeetingExport].self, from: Data(contentsOf: folder.appendingPathComponent("meetings.json"))), [])
        XCTAssertEqual(try decoder().decode(DataExport.DictionaryFile.self, from: Data(contentsOf: folder.appendingPathComponent("dictionary.json"))).dictionary, [])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("history.csv"), encoding: .utf8),
                       DataExport.csvColumns.map { "\"\($0)\"" }.joined(separator: ",") + "\r\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("dictionary.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("meetings").path), [])
    }

    func testAFailedExportThrowsAndLeavesNoFolder() throws {
        let s = try stores()
        // history.json and history.csv are written before the meeting fails to load.
        XCTAssertThrowsError(try DataExport.write(into: out, history: s.0, meetings: FailingStore(), dictionary: s.2, now: now, timeZone: utc))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "no partial folder")
        XCTAssertThrowsError(try DataExport.write(into: out.appendingPathComponent("gone"), history: s.0, meetings: s.1, dictionary: s.2))
    }

    func testASecondExportNeverOverwritesTheFirst() throws {
        let s = try stores()
        let first = try export(s)
        let marker = first.appendingPathComponent("history.json")
        try Data("kept".utf8).write(to: marker)
        let second = try export(s)
        XCTAssertEqual(second.lastPathComponent, "shepetal-export-2026-10-21-2")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "kept")
        XCTAssertEqual(try export(s).lastPathComponent, "shepetal-export-2026-10-21-3")
    }
}

/// Lists one meeting, then fails to read it.
private final class FailingStore: MeetingStoring {
    struct Broken: Error {}
    func save(_ meeting: Meeting) throws {}
    func append(_ segments: [Segment], to meetingID: String) throws {}
    func remove(_ segments: [Segment], from meetingID: String) throws {}
    func setSummary(_ summary: Summary, for meetingID: String) throws {}
    func setNotes(_ notes: String, for meetingID: String) throws {}
    func list(limit: Int) throws -> [Meeting] {
        [Meeting(id: "x", app: "Zoom", startedAt: Date(), meAudioPath: "", othersAudioPath: "")]
    }
    func search(_ query: String, limit: Int) throws -> [Meeting] { [] }
    func get(_ id: String) throws -> MeetingRecord? { throw Broken() }
    func delete(_ id: String) throws {}
}
