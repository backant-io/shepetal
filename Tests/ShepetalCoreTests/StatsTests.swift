import XCTest
@testable import ShepetalCore

/// F60: the Home tab's "Your stats". The numbers only mean something if they count text that reached the user's
/// app, so every test here is about what is counted and how.
final class StatsTests: XCTestCase {
    var root: URL!
    var history: History!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        history = try History(path: root.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        history = nil
        try? FileManager.default.removeItem(at: root)
    }

    func add(_ id: String, _ outcome: Outcome = .inserted, at t: Double = 1_000, words: Int, ms: Int = 1_000,
             app: String = "Notes", archived: Bool = false) throws {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        try history.add(HistoryEntry(id: id, createdAt: Date(timeIntervalSince1970: t), outcome: outcome,
                                     audioPath: "/a/\(id).wav", durationMs: ms, rawText: text, text: text,
                                     app: app, archived: archived))
    }

    // Text that never reached an app is not "words dictated". Each skipped row carries text and a duration,
    // so only its outcome can keep it out. Archiving hides a row from History; it was still dictated.
    func testOnlyDeliveredOutcomesCount() throws {
        try add("ins", .inserted, words: 3, ms: 1_000)
        try add("pf", .pasteFailed, words: 4, ms: 2_000)
        try add("arch", .inserted, words: 5, ms: 3_000, archived: true)
        for o in [Outcome.tooShort, .cancelled, .noSpeech, .failed] { try add(o.rawValue, o, words: 100, ms: 60_000) }
        let s = try history.stats()
        XCTAssertEqual(s.dictations, 3)
        XCTAssertEqual(s.words, 12)
        XCTAssertEqual(s.speakingMs, 6_000)
        XCTAssertEqual(s.apps, [.init(app: "Notes", words: 12)])
    }

    // 120 words in one minute of speech is 120 WPM. Typing them at 40 WPM takes 3 minutes, so 2 are saved.
    func testWpmAndTimeSaved() throws {
        try add("a", words: 80, ms: 40_000)
        try add("b", words: 40, ms: 20_000)
        let s = try history.stats()
        XCTAssertEqual(s.speakingMinutes, 1, accuracy: 1e-9)
        XCTAssertEqual(s.wpm, 120, accuracy: 1e-9)
        XCTAssertEqual(s.timeSavedMinutes, 2, accuracy: 1e-9, "default typing speed is 40 WPM")
        XCTAssertEqual(try history.stats(typingWpm: 60).timeSavedMinutes, 1, accuracy: 1e-9, "the typingWpm knob")
    }

    // Speaking slower than the user types saves nothing; it never shows negative time.
    func testSlowDictationSavesZeroNotNegative() throws {
        try add("slow", words: 10, ms: 60_000)
        let s = try history.stats()
        XCTAssertEqual(s.wpm, 10, accuracy: 1e-9)
        XCTAssertEqual(s.timeSavedMinutes, 0)
    }

    // Top apps: summed per app, most words first, ties by name, and a row without an app is "unknown app".
    func testPerAppGroupingAndOrdering() throws {
        try add("n1", words: 5, app: "Notes")
        try add("n2", words: 5, app: "Notes")
        try add("m", words: 3, app: "Mail")
        try add("u", words: 7, app: "")
        try add("s", words: 7, app: "Slack")
        XCTAssertEqual(try history.stats().apps, [
            .init(app: "Notes", words: 10), .init(app: "Slack", words: 7),
            .init(app: "unknown app", words: 7), .init(app: "Mail", words: 3),
        ])
    }

    // A fresh install shows zeros, not NaN or a crash from dividing by zero minutes.
    func testEmptyDatabaseIsAllZeros() throws {
        let s = try history.stats()
        XCTAssertEqual(s, DictationStats())
        XCTAssertEqual(s.wpm, 0)
        XCTAssertEqual(s.timeSavedMinutes, 0)
        XCTAssertEqual(s.speakingMinutes, 0)
        // Words > 0, or 0/0 is NaN and max(0, NaN) hides a missing guard. With words, x/0 is inf, and inf traps
        // StatsFormat.duration's Int(…), so `defaults write … typingWpm 0` would crash Home.
        var zero = DictationStats(typingWpm: 0)
        zero.words = 10
        XCTAssertEqual(zero.timeSavedMinutes, 0, "a zero typing speed must not divide by zero")
        // A dictation with zero duration (a clock glitch) must not give an infinite WPM.
        try add("z", words: 3, ms: 0)
        XCTAssertEqual(try history.stats().wpm, 0)
    }

    // "Last 7 days" counts rows at or after the cut, and all time counts everything.
    func testSinceFilter() throws {
        try add("old", at: 100, words: 1)
        try add("edge", at: 200, words: 2)
        try add("new", at: 300, words: 4)
        XCTAssertEqual(try history.stats(since: Date(timeIntervalSince1970: 200)).words, 6)
        XCTAssertEqual(try history.stats(since: Date(timeIntervalSince1970: 200)).dictations, 2)
        XCTAssertEqual(try history.stats(since: Date(timeIntervalSince1970: 301)), DictationStats())
        XCTAssertEqual(try history.stats().words, 7)
    }

    // Punctuation and dashes are not words; numbers and contractions are one word each.
    func testWordCount() {
        XCTAssertEqual(DictationStats.wordCount(""), 0)
        XCTAssertEqual(DictationStats.wordCount("Hello, world."), 2)
        XCTAssertEqual(DictationStats.wordCount("It's 3.5 km — fine!\nNext line"), 6)
        XCTAssertGreaterThan(DictationStats.wordCount("今日は良い天気です"), 1, "no spaces, still several words")
    }
}
