import XCTest
@testable import ShepetalCore

/// F61: the daily streak and the milestone notes next to 🤫. A streak is only worth showing if it counts the
/// days the user's text reached an app, in the user's own time zone, and a note is only welcome once.
final class StreakTests: XCTestCase {
    var root: URL!
    var history: History!
    var defaults: UserDefaults!
    let suite = "shepetal-streak-\(UUID().uuidString)"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-streak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        history = try History(path: root.appendingPathComponent("history.sqlite"))
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        history = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    lazy var berlin = calendar("Europe/Berlin")

    func at(_ day: Int, _ hour: Int = 12, _ minute: Int = 0, month: Int = 10, in cal: Calendar? = nil) -> Date {
        (cal ?? berlin).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @discardableResult
    func add(_ id: String, at t: Date, _ outcome: Outcome = .inserted, words: Int = 3) throws -> String {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        try history.add(HistoryEntry(id: id, createdAt: t, outcome: outcome, audioPath: "/a/\(id).wav",
                                     durationMs: 1_000, rawText: text, text: text, app: "Notes"))
        return id
    }

    func streak(today: Date, _ cal: Calendar? = nil) throws -> Int {
        Streak.streak(days: try history.rows().map(\.createdAt), today: today, calendar: cal ?? berlin)
    }

    // Two minutes apart across midnight are two days where the user lives, and one day where it was still
    // afternoon. The streak follows the calendar's time zone, not UTC.
    func testDayBoundariesFollowTheTimeZone() throws {
        try add("late", at: at(19, 23, 59))
        try add("early", at: at(20, 0, 1))
        XCTAssertEqual(try streak(today: at(20, 18)), 2)
        let la = calendar("America/Los_Angeles")  // both were on 19.10 there, in the afternoon
        XCTAssertEqual(try streak(today: at(20, 18), la), 1)
    }

    // Before the first dictation of the day, yesterday's streak still stands; a whole day without one ends it.
    func testStreakStaysAliveUntilADayIsMissed() throws {
        for d in [17, 18, 19] { try add("d\(d)", at: at(d)) }
        XCTAssertEqual(try streak(today: at(19, 23)), 3, "today has one")
        XCTAssertEqual(try streak(today: at(20, 8)), 3, "today has none yet: still alive")
        XCTAssertEqual(try streak(today: at(21, 8)), 0, "20.10 had none")
    }

    func testAGapBreaksTheStreak() throws {
        for d in [12, 13, 14, 16, 17, 18] { try add("d\(d)", at: at(d)) }
        XCTAssertEqual(try streak(today: at(18)), 3, "15.10 is missing, so only 16 to 18 count")
        XCTAssertEqual(Streak.streak(days: [], today: at(18), calendar: berlin), 0)
    }

    // Germany leaves summer time on 25.10.26 (a 25-hour day) and enters it on 29.03.26 (a 23-hour day).
    // Stepping back 24 h from a late-evening time lands on the wrong day around them.
    func testDaysAcrossDaylightSavingChanges() throws {
        try add("a", at: at(24, 23, 30))
        try add("b", at: at(25, 23, 30))
        try add("c", at: at(26, 0, 30))
        XCTAssertEqual(try streak(today: at(26, 23, 59)), 3)
        try add("m1", at: at(28, 0, 30, month: 3))
        try add("m2", at: at(29, 23, 30, month: 3))
        try add("m3", at: at(30, 0, 15, month: 3))
        XCTAssertEqual(try streak(today: at(30, 12, month: 3)), 3)
    }

    // A tap too short to record, Esc, silence and an engine error put nothing in the user's app: no day.
    func testUndeliveredDictationsDoNotCount() throws {
        try add("d18", at: at(18))
        try add("d19", at: at(19))
        for o in [Outcome.tooShort, .cancelled, .noSpeech, .failed] { try add(o.rawValue, at: at(20), o, words: 2_000) }
        try add("pf", at: at(17), .pasteFailed)  // the text waited on the clipboard: it was dictated
        XCTAssertEqual(try streak(today: at(20, 20)), 3, "today has only undelivered rows, so 17 to 19")
        for o in [Outcome.tooShort, .cancelled, .noSpeech, .failed] {
            XCTAssertNil(Streak.notice(after: o.rawValue, in: history, today: at(20, 20), calendar: berlin, defaults: defaults),
                         "\(o) reached 1,000 words only if it was counted")
        }
    }

    func testMilestonesBetweenTwoTotals() {
        typealias T = Milestone.Totals
        XCTAssertEqual(Streak.milestones(previous: T(), now: T(dictations: 1, words: 5, streak: 1)), [.firstDictation])
        XCTAssertEqual(Streak.milestones(previous: T(dictations: 9, words: 990, streak: 6), now: T(dictations: 10, words: 1_010, streak: 7)),
                       [.streak(7), .words(1_000)])
        XCTAssertEqual(Streak.milestones(previous: T(dictations: 10, words: 1_010, streak: 7), now: T(dictations: 11, words: 1_020, streak: 7)),
                       [], "the second dictation of the 7th day")
        // An update onto a long history must not replay every milestone already behind the user.
        XCTAssertEqual(Streak.milestones(previous: T(dictations: 900, words: 50_000, streak: 40), now: T(dictations: 901, words: 50_020, streak: 40)), [])
    }

    // 100 days, one 120-word dictation a day and a second one on some days: every milestone is told exactly
    // once, on the dictation that reaches it.
    func testEachMilestoneFiresOnceOnTheDictationThatReachesIt() throws {
        var told: [String: [Int]] = [:]
        let jan1 = berlin.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10))!
        for day in 1...100 {  // across the change to summer time on 29.03
            let t = berlin.date(byAdding: .day, value: day - 1, to: jan1)!
            for n in day % 10 == 7 ? [0, 1] : [0] {
                let id = try add("d\(day)-\(n)", at: t.addingTimeInterval(Double(n) * 60), words: n == 0 ? 120 : 1)
                if let note = Streak.notice(after: id, in: history, today: t.addingTimeInterval(3_600), calendar: berlin, defaults: defaults) {
                    told[note, default: []].append(day)
                }
            }
        }
        XCTAssertEqual(told, [
            Milestone.firstDictation.text: [1],
            Milestone.streak(7).text: [7],
            Milestone.words(1_000).text: [9],    // 8 × 120 = 960, 9 × 120 = 1,080
            Milestone.streak(30).text: [30],
            Milestone.words(10_000).text: [84],  // 83 × 120 + 8 one-word extras (days 7 to 77) = 9,968; + 120
            Milestone.streak(100).text: [100],
        ])
    }

    // Both reached on one dictation: one note with both, not one hidden behind the other.
    func testTwoMilestonesOnOneDictationShareOneNote() throws {
        for d in 13...18 { try add("d\(d)", at: at(d), words: 160) }  // 6 days, 960 words
        let id = try add("d19", at: at(19), words: 50)
        XCTAssertEqual(Streak.notice(after: id, in: history, today: at(19, 13), calendar: berlin, defaults: defaults),
                       Milestone.streak(7).text + " · " + Milestone.words(1_000).text)
    }

    // Settings › Milestone notices: on until the user turns it off.
    func testMilestoneNoticesSettingGatesTheNote() throws {
        let id = try add("first", at: at(20))
        XCTAssertEqual(Streak.notice(after: id, in: history, today: at(20, 13), calendar: berlin, defaults: defaults),
                       Milestone.firstDictation.text, "unset means on")
        defaults.set(false, forKey: Streak.noticesKey)
        XCTAssertNil(Streak.notice(after: id, in: history, today: at(20, 13), calendar: berlin, defaults: defaults))
        XCTAssertNil(Streak.notice(after: "not-a-row", in: history, today: at(20, 13), calendar: berlin, defaults: defaults))
    }

    func testMilestoneWording() {
        XCTAssertEqual(Milestone.streak(30).text, "30-day streak: you dictated every day")
        XCTAssertEqual(Milestone.words(10_000).text, "\(10_000.formatted()) words dictated so far")
        XCTAssertTrue(Milestone.firstDictation.text.contains("shepetal"), "labels say lowercase shepetal")
    }
}
