import XCTest
@testable import ShepetalCore

final class MeetingModelTests: XCTestCase {
    /// The channels are labelled "Me" and "Others" in the UI and in storage (meeting product rule).
    func testSpeakerLabelsAreMeAndOthers() throws {
        XCTAssertEqual(Speaker.allCases.map(\.rawValue), ["Me", "Others"])
        let json = try JSONEncoder().encode(Segment(speaker: .others, start: 1, end: 2.5, text: "hi"))
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"Others\""))
    }

    /// Stores persist summaries as JSON: a round trip must not lose action item owners or due dates.
    func testSummaryRoundTripsThroughJSON() throws {
        let s = Summary(overview: "Release planning.", keyPoints: ["Beta slips a week"],
                        decisions: ["Ship on Friday"],
                        actionItems: [ActionItem(owner: "Me", task: "send the notes", due: "Friday"),
                                      ActionItem(owner: "", task: "book a room")])
        XCTAssertEqual(try JSONDecoder().decode(Summary.self, from: JSONEncoder().encode(s)), s)
    }
}
