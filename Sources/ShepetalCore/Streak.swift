import Foundation

/// F61: the daily streak and the milestones, over the delivered dictations `History.rows(since:)` returns.
/// too_short, cancelled, no_speech and failed rows are not in those rows, so they never count.
public enum Streak {
    /// Settings › "Milestone notices". Unset means on.
    public static let noticesKey = "milestoneNotices"

    /// Consecutive local days (in `calendar`'s time zone) with at least one dictation, ending today. While today
    /// has none yet, the streak that ended yesterday is still alive; a whole day without one ends it.
    public static func streak(days: [Date], today: Date, calendar: Calendar = .current) -> Int {
        let have = Set(days.map { day($0, calendar) })
        var last = day(today, calendar)
        if !have.contains(last) { last -= 1 }
        var n = 0
        while have.contains(last - n) { n += 1 }
        return n
    }

    /// The local date as a number, one apart per calendar day: the wall-clock time in `calendar`'s time zone, in
    /// whole days. Not 86 400 s steps from now, since a day across a DST change is 23 or 25 hours long.
    /// (`ordinality(of: .day, in: .era)` puts 23:59 and 00:01 in Berlin on one day, and
    /// `dateComponents(_:from:to:)` takes about 70 µs a row.)
    static func day(_ t: Date, _ calendar: Calendar) -> Int {
        let wallClock = t.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: t))
        return Int((wallClock / 86_400).rounded(.down))
    }

    /// What `now` reached that `previous` had not. Each one is told on the one dictation that reaches it.
    public static func milestones(previous: Milestone.Totals, now: Milestone.Totals) -> [Milestone] {
        var reached: [Milestone] = []
        if previous.dictations == 0, now.dictations > 0 { reached.append(.firstDictation) }
        reached += Milestone.streakDays.filter { previous.streak < $0 && now.streak >= $0 }.map(Milestone.streak)
        reached += Milestone.wordCounts.filter { previous.words < $0 && now.words >= $0 }.map(Milestone.words)
        return reached
    }

    /// The note next to 🤫 after the dictation `id`: nil when it reached no milestone, when it was not delivered
    /// (then it is not in the rows), or when Milestone notices is off.
    /// It reads and word-counts every delivered row (about 25 µs a row), so the app runs it off the main thread.
    /// ponytail: a full read per dictation; keep running totals in History if it gets slow.
    public static func notice(after id: String, in history: History, today: Date = Date(),
                              calendar: Calendar = .current, defaults: UserDefaults = .standard) -> String? {
        guard defaults.object(forKey: noticesKey) as? Bool ?? true, let rows = try? history.rows(),
              let newest = rows.last(where: { $0.id == id }) else { return nil }
        let now = Milestone.Totals(rows, today: today, calendar: calendar)
        let before = Milestone.Totals(
            dictations: now.dictations - 1, words: now.words - DictationStats.wordCount(newest.text),
            streak: streak(days: rows.filter { $0.id != id }.map(\.createdAt), today: today, calendar: calendar))
        let reached = milestones(previous: before, now: now)
        return reached.isEmpty ? nil : reached.map(\.text).joined(separator: " · ")
    }
}

public enum Milestone: Equatable {
    case firstDictation
    case streak(Int)
    case words(Int)

    public static let streakDays = [7, 30, 100]
    public static let wordCounts = [1_000, 10_000, 100_000]

    /// In our own words.
    public var text: String {
        switch self {
        case .firstDictation: "Your first dictation with shepetal"
        case .streak(let days): "\(days)-day streak: you dictated every day"
        case .words(let n): "\(n.formatted()) words dictated so far"
        }
    }

    /// The totals a milestone is measured on.
    public struct Totals: Equatable {
        public var dictations: Int
        public var words: Int
        public var streak: Int

        public init(dictations: Int = 0, words: Int = 0, streak: Int = 0) {
            self.dictations = dictations; self.words = words; self.streak = streak
        }

        /// `rows`: delivered dictations (`History.rows(since:)`).
        public init(_ rows: [HistoryEntry], today: Date, calendar: Calendar = .current) {
            self.init(dictations: rows.count, words: rows.reduce(0) { $0 + DictationStats.wordCount($1.text) },
                      streak: Streak.streak(days: rows.map(\.createdAt), today: today, calendar: calendar))
        }
    }
}
