import AppKit
@testable import ShepetalCore
import XCTest
@testable import Shepetal

/// F61, F62: what Home's Insights prints, and that the section appears once the first dictation lands.
@MainActor
final class InsightsFormatTests: XCTestCase {
    func entry(_ text: String, at t: Date, app: String = "Notes", _ outcome: Outcome = .inserted) -> HistoryEntry {
        HistoryEntry(id: UUID().uuidString, createdAt: t, outcome: outcome, audioPath: "", durationMs: 1_000,
                     rawText: text, text: text, app: app)
    }

    func testStreakLine() {
        XCTAssertEqual(InsightsFormat.streak(0), "No streak right now: dictate today to start one")
        XCTAssertEqual(InsightsFormat.streak(12), "12-day streak")
    }

    func testCardLeavesOutWhatIsNotKnown() throws {
        let now = Date()
        let full = try XCTUnwrap(Insights([entry("Deploy the build.", at: now, app: "Slack"),
                                           entry("deploy the build", at: now, app: "Slack")], today: now))
        let hour = Calendar.current.component(.hour, from: now)
        XCTAssertEqual(InsightsFormat.card(full), [
            .init(title: "Busiest hour", value: String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)),
            .init(title: "Top app", value: "Slack"),
            .init(title: "Most-used word", value: "“build”"),
            .init(title: "Favourite phrase", value: "“deploy the build”"),
            .init(title: "Words so far", value: "6 · next milestone \(1_000.formatted())"),
        ])
        // No app recorded and nothing said twice: only the hour and the total.
        let thin = try XCTUnwrap(Insights([entry("hello there", at: now, app: "")], today: now))
        XCTAssertEqual(InsightsFormat.card(thin).map(\.title), ["Busiest hour", "Words so far"])
        var past = thin
        past.words = 123_456; past.nextMilestone = nil
        XCTAssertEqual(InsightsFormat.card(past).last?.value, 123_456.formatted())
    }

    func testHourWrapsAtMidnight() throws {
        var i = try XCTUnwrap(Insights([entry("hi", at: Date())]))
        i.peakHour = 23
        XCTAssertEqual(InsightsFormat.card(i).first?.value, "23:00–00:00")
    }

    // Dates as DD.MM.YY on every locale.
    func testSquareLabel() throws {
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        let day = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 21)))
        XCTAssertEqual(InsightsFormat.day(.init(date: day, words: 120, level: 3), timeZone: berlin), "21.10.26: 120 words")
        XCTAssertEqual(InsightsFormat.day(.init(date: day, words: 1, level: 1), timeZone: berlin), "21.10.26: 1 word")
        XCTAssertEqual(InsightsFormat.day(.init(date: day, words: 0, level: 0), timeZone: berlin), "21.10.26: 0 words")
    }

    // A hidden section has no view whose onAppear could load it, so the model must pick up the first
    // dictation by itself when the user comes back to the window.
    func testModelShowsTheSectionAfterTheFirstDictation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-insights-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try History(path: root.appendingPathComponent("history.sqlite"))
        let model = InsightsModel(history: history)
        XCTAssertNil(model.insights, "empty history: hidden")
        try history.add(entry("first words", at: Date()))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        XCTAssertEqual(model.insights?.words, 2)
        XCTAssertEqual(model.labels.count, model.insights?.days.count, "one label per square")
        XCTAssertTrue(model.labels.last?.hasSuffix(": 2 words") == true)
        // Switching to Home in a window that is already key makes a new model and posts nothing.
        XCTAssertEqual(InsightsModel(history: history).insights?.words, 2, "a new model loads at once")
    }
}
