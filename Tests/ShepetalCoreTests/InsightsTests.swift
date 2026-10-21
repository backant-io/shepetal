import XCTest
@testable import ShepetalCore

/// F62: Home's Insights. The heatmap and the card describe what the user dictated into apps, by their own
/// days and hours, and must read the same every time the window opens.
final class InsightsTests: XCTestCase {
    var root: URL!
    var history: History!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-insights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        history = try History(path: root.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        history = nil
        try? FileManager.default.removeItem(at: root)
    }

    func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = firstWeekday
        return c
    }

    lazy var berlin = calendar("Europe/Berlin")

    func at(_ day: Int, _ hour: Int = 12, _ minute: Int = 0, month: Int = 10, in cal: Calendar? = nil) -> Date {
        (cal ?? berlin).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    var counter = 0
    func row(_ text: String, at t: Date, app: String = "Notes", _ outcome: Outcome = .inserted, archived: Bool = false) -> HistoryEntry {
        counter += 1
        return HistoryEntry(id: "r\(counter)", createdAt: t, outcome: outcome, audioPath: "", durationMs: 1_000,
                            rawText: text, text: text, app: app, archived: archived)
    }

    func words(_ n: Int, _ w: String = "word") -> String { Array(repeating: w, count: n).joined(separator: " ") }

    func insights(_ rows: [HistoryEntry], today: Date? = nil, _ cal: Calendar? = nil) throws -> Insights {
        try XCTUnwrap(Insights(rows, today: today ?? at(21, 18), calendar: cal ?? berlin))
    }

    // The rows behind Insights and the streak: what reached an app (archived too, since archiving only hides a
    // row from History), oldest first. Too short, cancelled, no speech and failed rows carry text here, so only
    // their outcome keeps them out.
    func testRowsSinceKeepsDeliveredRowsOldestFirst() throws {
        try history.add(row("new", at: at(21)))
        try history.add(row("waited on the clipboard", at: at(20), .pasteFailed))
        try history.add(row("hidden", at: at(19), archived: true))
        for o in [Outcome.tooShort, .cancelled, .noSpeech, .failed] { try history.add(row("deploy deploy", at: at(20), o)) }
        XCTAssertEqual(try history.rows().map(\.text), ["hidden", "waited on the clipboard", "new"])
        XCTAssertEqual(try history.rows(since: at(20)).map(\.text), ["waited on the clipboard", "new"], "at or after")
        XCTAssertEqual(try history.rows(since: at(21, 12, 1)), [])
    }

    // Ten minutes apart across midnight are two squares in Berlin, and one square in UTC, where it was evening.
    func testDayBucketingAcrossMidnight() throws {
        let rows = [row(words(10), at: at(20, 23, 50)), row(words(5), at: at(21, 0, 10))]
        let local = try insights(rows)
        XCTAssertEqual(local.days.suffix(2).map(\.words), [10, 5])
        let other = try insights(rows, today: at(21, 18), calendar("UTC"))
        XCTAssertEqual(other.days.suffix(2).map(\.words), [15, 0], "21:50 and 22:10 UTC on 20.10")
        XCTAssertEqual(local.days.last?.date, berlin.startOfDay(for: at(21)), "the last square is today")
    }

    // 25.10.26 is 25 hours long in Berlin. Each day still gets its own square, one calendar day apart, where a
    // 24-hour step would put two of these in one square or skip one.
    func testDaysAcrossTheDaylightSavingChange() throws {
        let i = try insights([row(words(1), at: at(24, 23, 30)), row(words(2), at: at(25, 23, 30)),
                              row(words(3), at: at(26, 0, 30))], today: at(26, 20))
        XCTAssertEqual(i.days.suffix(3).map(\.words), [1, 2, 3])
        XCTAssertEqual(i.days.suffix(3).map { berlin.component(.day, from: $0.date) }, [24, 25, 26])
        XCTAssertTrue(i.days.allSatisfy { berlin.startOfDay(for: $0.date) == $0.date }, "each square is a local midnight")
    }

    // 26 week columns that start on the calendar's first weekday, ending at today's row in the last one.
    func testGridIsTwentySixWeeksEndingToday() throws {
        let rows = [row("hi", at: at(21))]  // Wednesday 21.10.26
        let monday = try insights(rows, today: at(21, 9))
        XCTAssertEqual(monday.days.count, 25 * 7 + 3, "Mon, Tue, Wed of this week")
        XCTAssertEqual(berlin.component(.weekday, from: monday.days[0].date), 2)
        let sundayCal = calendar("Europe/Berlin", firstWeekday: 1)
        let sunday = try insights(rows, today: at(21, 9), sundayCal)
        XCTAssertEqual(sunday.days.count, 25 * 7 + 4)
        XCTAssertEqual(sundayCal.component(.weekday, from: sunday.days[0].date), 1)
        // A row older than the grid counts in the totals, not in a square.
        let old = try insights([row("hi", at: at(1, month: 1)), row("hi", at: at(21))], today: at(21, 9))
        XCTAssertEqual(old.days.map(\.words).reduce(0, +), 1)
        XCTAssertEqual(old.words, 2)
    }

    // 0 for a day without words; 1 to 4 by quartile among the days with words.
    func testHeatmapLevelsByQuartile() throws {
        let i = try insights([row(words(1), at: at(14)), row(words(2), at: at(15)), row(words(3), at: at(16)),
                              row(words(40), at: at(17))])
        XCTAssertEqual(i.days.suffix(9).map(\.level), [0, 1, 2, 3, 4, 0, 0, 0, 0])  // 13.10 to 21.10
        XCTAssertEqual(try insights([row(words(7), at: at(21))]).days.last?.level, 1, "a single day")
        // A busy day older than the grid is not one of its days, so it does not push the shades down.
        let withOld = try insights([row(words(1_000), at: at(5, month: 1)), row(words(1), at: at(14)), row(words(2), at: at(15)),
                                    row(words(3), at: at(16)), row(words(40), at: at(17))])
        XCTAssertEqual(withOld.days.suffix(9).map(\.level), [0, 1, 2, 3, 4, 0, 0, 0, 0])
    }

    // Too short, cancelled, no speech and failed never reached an app: not in a square, not in the card.
    func testUndeliveredRowsAreLeftOut() throws {
        try history.add(row("hello hello", at: at(21, 9), app: "Mail"))
        for o in [Outcome.tooShort, .cancelled, .noSpeech, .failed] {
            try history.add(row(words(50, "deploy"), at: at(21, 15), app: "Slack", o))
        }
        let i = try insights(try history.rows())
        XCTAssertEqual(i.words, 2)
        XCTAssertEqual(i.days.last?.words, 2)
        XCTAssertEqual(i.topApp, "Mail")
        XCTAssertEqual(i.topWord, "hello")
        XCTAssertEqual(i.peakHour, 9)
    }

    // "the" and "und" are said most and mean nothing; the card names the word the user's dictation is about.
    func testTopWordSkipsStopwordsAndNumbers() throws {
        let i = try insights([row("The deploy and the build, the deploy.", at: at(21)),
                              row("Und das 42 ist 42, und das Deploy", at: at(21))])
        XCTAssertEqual(i.topWord, "deploy")
        XCTAssertNil(try insights([row("the the and and 7 7", at: at(21))]).topWord)
        XCTAssertNil(try insights([row("once only", at: at(21))]).topWord, "a word needs two uses")
    }

    // The longest phrase among the most frequent: every use of "let me know" is also a use of "let me".
    // Phrases of stopwords only ("of the") are not a phrase of the user's.
    func testTopPhrase() throws {
        let i = try insights([row("Let me know today.", at: at(21)), row("Please let me know", at: at(21))])
        XCTAssertEqual(i.topPhrase, "let me know")
        XCTAssertNil(try insights([row("of the of the", at: at(21))]).topPhrase)
        XCTAssertNil(try insights([row("let me know", at: at(21))]).topPhrase, "a phrase needs two uses")
        // Typographic and straight apostrophes are one word.
        XCTAssertEqual(try insights([row("Ship it’s done", at: at(21)), row("ship it's done", at: at(21))]).topPhrase,
                       "ship it's done")
    }

    // Equal counts always pick the same winner, whatever order the rows come in, so the card does not change
    // between two openings of the window.
    func testTiesAreDeterministic() throws {
        let rows = [row("zulu zulu", at: at(21, 14), app: "Zed"), row("alpha alpha", at: at(21, 9), app: "Arc"),
                    row("beta gamma beta gamma", at: at(21, 14), app: "Mail"), row("x y", at: at(21, 9), app: "")]
        for order in [rows, rows.reversed(), [rows[2], rows[0], rows[3], rows[1]]] {
            let i = try insights(order)
            XCTAssertEqual(i.topWord, "alpha", "two uses each: first by name")
            XCTAssertEqual(i.topPhrase, "beta gamma")
            XCTAssertEqual(i.peakHour, 14, "6 words at 14:00, 4 at 09:00")
            XCTAssertEqual(i.topApp, "Mail", "a row without an app is not named")
        }
        let tie = try insights([row(words(2), at: at(21, 16), app: "Notes"), row(words(2), at: at(21, 8), app: "Mail")])
        XCTAssertEqual(tie.peakHour, 8, "same words: the earlier hour")
        XCTAssertEqual(tie.topApp, "Mail", "same words: first by name")
        let unnamed = try insights([row(words(9), at: at(21), app: ""), row(words(1), at: at(21), app: "Mail")])
        XCTAssertEqual(unnamed.topApp, "Mail", "most words had no app recorded: the card names an app, not a blank")
        XCTAssertNil(try insights([row(words(9), at: at(21), app: "")]).topApp)
    }

    func testTotalWordsAndNextMilestone() throws {
        XCTAssertEqual(try insights([row(words(1_200), at: at(21))]).nextMilestone, 10_000)
        XCTAssertEqual(try insights([row(words(10_000), at: at(21))]).nextMilestone, 100_000, "reached is not next")
        let past = try insights([row(words(100_001, "x"), at: at(21))])
        XCTAssertEqual(past.words, 100_001)
        XCTAssertNil(past.nextMilestone)
    }

    // A fresh install, or one with only taps and cancels, shows no Insights section at all.
    func testEmptyHistoryHidesTheSection() throws {
        XCTAssertNil(Insights(try history.rows(), today: at(21), calendar: berlin))
        try history.add(row("deploy deploy", at: at(21), .cancelled))
        XCTAssertNil(Insights(try history.rows(), today: at(21), calendar: berlin))
        try history.add(row("deploy deploy", at: at(21)))
        XCTAssertNotNil(Insights(try history.rows(), today: at(21), calendar: berlin))
    }

    func testStreakOnTheCard() throws {
        let i = try insights([row("a", at: at(19)), row("b", at: at(20))], today: at(21, 9))
        XCTAssertEqual(i.streak, 2, "today has none yet")
    }
}
