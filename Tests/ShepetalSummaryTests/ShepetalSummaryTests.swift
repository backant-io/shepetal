import XCTest
import ShepetalCore
@testable import ShepetalSummary

/// The Swift summarizer must say what summarize/summarize.py says, because that is the version that was measured
/// (docs/summarization.md). python_golden.json is its output on summarize/fixtures (summarize/export_golden.py).
final class ShepetalSummaryTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Golden: Decodable {
        let overview: String
        let overview_top3: [String]
        let key_points: [String]
        let decisions: [String]
        let actions: [[String]]
        let action_scores: [Double]
    }

    /// summarize.py parse(): "Name: text" per line; a line without a colon has no speaker.
    func turns(_ text: String) -> [(speaker: String, text: String)] {
        text.components(separatedBy: "\n").map { line in
            guard let c = line.firstIndex(of: ":") else { return ("", line) }
            return (line[..<c].trimmingCharacters(in: .whitespaces), String(line[line.index(after: c)...]))
        }
    }

    func testMatchesPythonOnTheFixtureMeetings() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("Tests/ShepetalSummaryTests/python_golden.json"))
        let golden = try JSONDecoder().decode([String: Golden].self, from: data)
        XCTAssertEqual(golden.count, 3)
        let s = try MeetingSummarizer()
        for (name, want) in golden.sorted(by: { $0.key < $1.key }) {
            let text = try String(contentsOf: Self.repo.appendingPathComponent("summarize/fixtures/" + name), encoding: .utf8)
            let got = s.summarize(turns: turns(text))
            // Every feature and weight of the AMI classifier, ported: same probability for every sentence.
            let sents = turns(text).flatMap { t in sentences(t.text).map { Sent(spk: t.speaker, text: $0) } }
            let scores = s.actionScores(sents)
            XCTAssertEqual(scores.count, want.action_scores.count, name)
            for (a, b) in zip(scores, want.action_scores) { XCTAssertEqual(a, b, accuracy: 1e-9, name) }
            // Who owns what, and by when, is what people act on: it must match exactly.
            XCTAssertEqual(got.actionItems.map { [$0.owner, $0.task, $0.due] }, want.actions, name)
            XCTAssertEqual(got.decisions, want.decisions, name)
            XCTAssertTrue(want.overview_top3.contains(got.overview), "\(name): overview \(got.overview)")
            XCTAssertEqual(got.overview, want.overview, name)
            XCTAssertEqual(got.keyPoints, want.key_points, name)
        }
    }

    /// A task handed out with "you" belongs to whoever answers, not to whoever spoke before.
    func testYouGoesToWhoeverAnswers() {
        let sents = [Sent(spk: "Ann", text: "Hi."), Sent(spk: "Ben", text: "You send the deck."), Sent(spk: "Cleo", text: "Sure.")]
        XCTAssertEqual(owner(sents, 1, aliases(sents)), "Cleo")
    }

    /// In the app the speakers are the two channels, so owners come out as "Me" and "Others".
    func testOwnersAreTheChannelLabels() throws {
        let got = try MeetingSummarizer().summarize([
            Segment(speaker: .others, start: 0, end: 4, text: "Thanks for joining. I will send the signed contract by Friday."),
            Segment(speaker: .me, start: 4, end: 8, text: "Great. I'll book the follow-up review for next Thursday."),
        ])
        XCTAssertEqual(got.actionItems, [
            ActionItem(owner: "Others", task: "send the signed contract", due: "Friday"),
            ActionItem(owner: "Me", task: "book the follow-up review", due: "next Thursday"),
        ])
    }

    func testSilentMeetingGivesAnEmptySummary() throws {
        XCTAssertEqual(try MeetingSummarizer().summarize([]), Summary(overview: ""))
        XCTAssertEqual(try MeetingSummarizer().summarize([Segment(speaker: .me, start: 0, end: 1, text: "  ")]), Summary(overview: ""))
    }

    /// The bundled weights must be the ones summarize/ami_actions.py trained, not a stale copy.
    func testBundledModelIsTheTrainedOne() throws {
        let bundled = try XCTUnwrap(MeetingSummarizer.bundledModel)
        XCTAssertEqual(try Data(contentsOf: bundled),
                       try Data(contentsOf: Self.repo.appendingPathComponent("summarize/actions_model.json")))
    }

    /// The packaged app keeps the resource bundle in Contents/Resources (scripts/make-app.sh): it must be found there.
    func testFindsTheModelBundleInAResourcesDir() throws {
        let resources = Bundle.module.bundleURL.deletingLastPathComponent()
        XCTAssertEqual(MeetingSummarizer.modelURL(inResources: resources)?.lastPathComponent, "actions_model.json")
        XCTAssertNil(MeetingSummarizer.modelURL(inResources: Self.repo))
    }

    func testMissingModelThrows() {
        XCTAssertThrowsError(try MeetingSummarizer(modelURL: URL(fileURLWithPath: "/nonexistent/actions_model.json")))
    }
}
