import XCTest
@testable import ShepetalCore

/// F73: asking across all meetings starts with the search index, which ranks the meetings by BM25 before the
/// answers are ranked line by line. Temp dirs only.
final class MeetingShortlistTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-shortlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func add(_ store: MeetingStoring, _ id: String, at t: Double, _ lines: [String]) throws {
        try store.save(Meeting(id: id, app: "Zoom", startedAt: Date(timeIntervalSince1970: t), meAudioPath: "", othersAudioPath: ""))
        try store.append(lines.enumerated().map { Segment(speaker: .others, start: Double($0), end: Double($0) + 1, text: $1) }, to: id)
    }

    func testMeetingsThatSayMostComeFirst() throws {
        let store = try MeetingStore(path: root.appendingPathComponent("meetings.sqlite"))
        try add(store, "a-once", at: 3, ["We talked about the roadmap for a long time and then, briefly, the budget."])
        try add(store, "z-often", at: 1, ["The budget.", "Budgets again.", "Who owns the BUDGET?"])
        try add(store, "never", at: 2, ["Only the roadmap."])
        XCTAssertEqual(try store.shortlist(["budg"], limit: 10), ["z-often", "a-once"], "BM25 order, not newest first")
        XCTAssertEqual(try store.shortlist(["budg"], limit: 1), ["z-often"])
        XCTAssertEqual(Set(try store.shortlist(["budg", "roadmap"], limit: 10)), ["z-often", "a-once", "never"], "any of the terms")
        XCTAssertEqual(try store.shortlist(["no", "a"], limit: 10), [], "the trigram index needs 3 characters")
        XCTAssertEqual(try store.shortlist([], limit: 10), [])
        XCTAssertEqual(try store.shortlist(["\"budg"], limit: 10), [], "a quote in a term is no syntax error")

        try store.setSummary(Summary(overview: "", actionItems: [ActionItem(owner: "Me", task: "send the slides")]), for: "never")
        XCTAssertEqual(try store.shortlist(["slid"], limit: 10), ["never"], "summaries are searched too")
        try store.delete("z-often")
        XCTAssertEqual(try store.shortlist(["budg"], limit: 10), ["a-once"])
    }
}
