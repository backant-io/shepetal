import Foundation

/// F62: Home's Insights, over the delivered dictations (`History.rows(since:)`): words per local day for the last
/// 26 weeks as a heatmap, and a card of how you dictate. Counting only, no model, in our own wording.
public struct Insights: Equatable {
    public struct Day: Equatable {
        public var date: Date  // the local day's start
        public var words: Int
        /// 0: no words. 1 to 4: the quartile of this day among the days with words.
        public var level: Int
    }

    public static let weeks = 26

    /// One column per week, starting on the calendar's first weekday, oldest first and ending today, so the
    /// last column stops at today's row.
    public var days: [Day]
    public var streak: Int
    public var words: Int
    /// The next word milestone, nil past the last one.
    public var nextMilestone: Int?
    /// The local hour (0 to 23) with the most words.
    public var peakHour: Int?
    public var topApp: String?
    /// The most-used word that is not a stopword, and the most frequent 2 or 3 word phrase; each needs 2 uses.
    public var topWord: String?
    public var topPhrase: String?

    /// nil when nothing was delivered yet: Home hides the section.
    /// ponytail: tokenizes every delivered row on each reload; keep counts in History if it gets slow.
    public init?(_ rows: [HistoryEntry], today: Date = Date(), calendar: Calendar = .current) {
        guard !rows.isEmpty else { return nil }
        let todayN = Streak.day(today, calendar)
        let row = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let firstN = todayN - row - (Self.weeks - 1) * 7

        var perDay: [Int: Int] = [:], perHour: [Int: Int] = [:], perApp: [String: Int] = [:]
        var wordUses: [String: Int] = [:], phraseUses: [String: Int] = [:]
        words = 0
        for r in rows {
            let tokens = Self.tokens(r.text)
            words += tokens.count
            let n = Streak.day(r.createdAt, calendar)
            if n >= firstN { perDay[n, default: 0] += tokens.count }
            perHour[calendar.component(.hour, from: r.createdAt), default: 0] += tokens.count
            if !r.app.isEmpty { perApp[r.app, default: 0] += tokens.count }
            for t in tokens where Self.counts(t) { wordUses[t, default: 0] += 1 }
            for n in 2...3 where tokens.count >= n {
                for i in 0...(tokens.count - n) where tokens[i..<i + n].contains(where: Self.counts) {
                    phraseUses[tokens[i..<i + n].joined(separator: " "), default: 0] += 1
                }
            }
        }

        // Quartiles of the days with words: the cut below which a quarter, half and three quarters of them fall.
        let used = perDay.values.filter { $0 > 0 }.sorted()
        let cuts = used.isEmpty ? [] : [0.25, 0.5, 0.75].map { used[Int($0 * Double(used.count - 1))] }
        let start = calendar.startOfDay(for: today)
        days = (firstN...todayN).map { n in
            let w = perDay[n] ?? 0
            let date = calendar.startOfDay(for: calendar.date(byAdding: .day, value: n - todayN, to: start) ?? start)
            return Day(date: date, words: w, level: w == 0 ? 0 : 1 + cuts.filter { $0 < w }.count)
        }
        streak = Streak.streak(days: rows.map(\.createdAt), today: today, calendar: calendar)
        nextMilestone = Milestone.wordCounts.first { $0 > words }
        peakHour = Self.top(perHour.filter { $0.value > 0 }, by: <)
        topApp = Self.top(perApp.filter { $0.value > 0 }, by: <)
        topWord = Self.top(wordUses.filter { $0.value >= 2 }, by: <)
        // On a tie the longer phrase wins: "let me know" over "let me", which it always contains.
        topPhrase = Self.top(phraseUses.filter { $0.value >= 2 }) { a, b in
            let (na, nb) = (a.split(separator: " ").count, b.split(separator: " ").count)
            return na != nb ? na > nb : a < b
        }
    }

    /// Lowercased words as the system's word breaks see them (the same count as `DictationStats.wordCount`),
    /// with ’ as '.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { w, _, _, _ in
            if let w { out.append(w.lowercased().replacingOccurrences(of: "’", with: "'")) }
        }
        return out
    }

    /// A word worth naming: it has a letter and is not a stopword.
    static func counts(_ token: String) -> Bool {
        token.contains(where: \.isLetter) && !stopwords.contains(token)
    }

    /// The key with the highest count; a tie goes to the key `first` puts first, so the card never flickers.
    private static func top<K>(_ counts: [K: Int], by first: (K, K) -> Bool) -> K? {
        counts.max { a, b in a.value != b.value ? a.value < b.value : first(b.key, a.key) }?.key
    }

    /// English and German, the languages the text rules cover. Set(_:) because a few are in both lists.
    static let stopwords = Set([
        "a", "about", "after", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "because", "been",
        "before", "but", "by", "can", "could", "did", "do", "does", "don't", "for", "from", "get", "got", "had", "has",
        "have", "he", "her", "here", "him", "his", "how", "i", "i'm", "i've", "i'll", "i'd", "if", "in", "into", "is",
        "it", "it's", "its", "just", "like", "me", "more", "my", "no", "not", "now", "of", "off", "ok", "okay", "on",
        "one", "only", "or", "our", "out", "over", "really", "so", "some", "than", "that", "that's", "the", "their",
        "them", "then", "there", "these", "they", "this", "those", "to", "too", "up", "us", "very", "was", "we",
        "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "yeah", "yes", "you",
        "you're", "your", "um", "uh",
        "aber", "als", "also", "am", "an", "auch", "auf", "aus", "bei", "bin", "bis", "bist", "da", "dann", "das",
        "dass", "dem", "den", "der", "des", "die", "dir", "doch", "du", "ein", "eine", "einem", "einen", "einer",
        "es", "für", "hab", "habe", "haben", "hat", "ich", "ihr", "im", "in", "ist", "ja", "jetzt", "kann", "mal",
        "man", "mich", "mir", "mit", "nach", "nicht", "noch", "nur", "oder", "schon", "sein", "sich", "sie", "sind",
        "so", "über", "um", "und", "uns", "von", "vor", "war", "was", "wenn", "wie", "wir", "wird", "zu", "zum", "zur",
        "ähm", "äh",
    ])
}
