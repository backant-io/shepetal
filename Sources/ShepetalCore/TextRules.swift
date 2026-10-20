import Foundation

/// Fits dictated text to the text around the cursor (docs/re/insertion-context.md 2.2 and 2.5):
/// spacing, first-letter case and trailing punctuation. Only the cursor's line counts: the last line
/// of `before` and the first line of `after`. `selected` is the text the paste replaces.
public enum InsertionRules {
    static let sentenceEnd: Set<Character> = [".", "!", "?"]
    static let opening: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "@", "#"]
    /// The space before a following word is non-breaking, so apps that trim trailing ASCII spaces keep it.
    public static let nbsp = "\u{00A0}"

    public static func fit(_ dictated: String, before: String, after: String, selected: String = "") -> String {
        var text = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let before = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        let after = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? ""
        let sel = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = String(selected.prefix(while: \.isWhitespace))
        let trail = sel.isEmpty ? "" : String(selected.reversed().prefix(while: \.isWhitespace).reversed())

        let prev = before.last(where: { !$0.isWhitespace })
        let midSentence = prev.map { !sentenceEnd.contains($0) } ?? false

        // Case: the selection's first letter when it has one that says something (not "I" or an acronym),
        // else lowercase mid-sentence. Our own "I" and acronyms are never lowercased.
        if let f = sel.first(where: \.isLetter), keepsLowercase(firstWord(sel)) {
            if f.isUppercase { text = text.prefix(1).uppercased() + text.dropFirst() }
            else if keepsLowercase(firstWord(text)) { text = text.prefix(1).lowercased() + text.dropFirst() }
        } else if midSentence, keepsLowercase(firstWord(text)) {
            text = text.prefix(1).lowercased() + text.dropFirst()
        }

        // Sentence end: match the selection's, else drop ours when the sentence goes on after the cursor: the next
        // character is lowercase, a comma-like mark or the sentence's own end, or any word follows mid-sentence.
        let continues = after.first(where: { !$0.isWhitespace }).map {
            $0.isLowercase || ",;:".contains($0) || sentenceEnd.contains($0) || (midSentence && ($0.isLetter || $0.isNumber))
        } ?? false
        if let end = sel.last, sentenceEnd.contains(end) {
            if let last = text.last, !sentenceEnd.contains(last) { text.append(end) }
        } else if !sel.isEmpty || continues {
            // A final "DD.MM." keeps its dot: it is the date's, not the sentence's (docs/text-rules.md).
            while let last = text.last, sentenceEnd.contains(last),
                  text.range(of: #"(?<![\w.])[0-9]{2}\.[0-9]{2}\.$"#, options: .regularExpression) == nil {
                text.removeLast()
            }
        }

        if !lead.isEmpty { text = lead + text }
        else if let c = before.last, !c.isWhitespace, !opening.contains(c) { text = " " + text }
        if !trail.isEmpty { text += trail }
        else if let c = after.first, c.isLetter || c.isNumber { text += nbsp }
        return text
    }

    static func firstWord(_ s: String) -> Substring {
        s.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
    }

    /// False for "I", "I'm" and acronyms like "API".
    /// ponytail: a name that opens a mid-sentence dictation ("John will…") is lowercased. NLTagger's name tags
    /// were wrong on 10 of 44 short fragments ("Quick brown", "Mark it done"); a user dictionary would cover names.
    static func keepsLowercase(_ word: Substring) -> Bool {
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return false }
        let letters = word.filter(\.isLetter)
        return !(letters.count > 1 && letters.allSatisfy(\.isUppercase))
    }
}

/// The pure part of the paste-success check. An app pulling our pasteboard data after Cmd+V
/// means the paste landed; no pull within `failAfter` means it failed.
public enum PasteCheck {
    public enum Verdict: Equatable { case waiting, landed, failed }
    public static let failAfter: TimeInterval = 1.0
    public static let restoreDelay: TimeInterval = 0.5

    /// A read before Cmd+V (a clipboard manager) does not count as the paste.
    public static func verdict(postedAt: TimeInterval, requestedAt: TimeInterval?, now: TimeInterval) -> Verdict {
        if let r = requestedAt, r >= postedAt { return .landed }
        return now - postedAt >= failAfter ? .failed : .waiting
    }

    /// When to put the user's clipboard back.
    public static func restoreAt(postedAt: TimeInterval, requestedAt: TimeInterval?) -> TimeInterval {
        if let r = requestedAt, r >= postedAt { return r + restoreDelay }
        return postedAt + failAfter
    }
}

/// Deterministic cleanup that runs before insertion: drops fillers and stutters, tidies spaces.
/// Only words that are never doubled in correct English count as stutters ("the the"); "had had",
/// "that that" and "very very" are what the user said.
/// The local-LLM cleanup comes later and runs after this.
public enum Cleanup {
    public static func apply(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsUpper = s.first?.isUppercase ?? false
        s = s.replacingOccurrences(of: #"(?i)(?<![\w-])(?:u+m+|u+h+|uhm|erm|hmm+)(?![\w-])[,.]?\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\b(the|an?|and|i)(?:\s+\1\b)+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if startsUpper, let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }
}

/// Spoken dates become numbers, `DD.MM.YY` or `DD.MM.` (docs/text-rules.md). English and German words at once,
/// since the rule is not told the language. Runs on the cleaned text, before the dictionary and `fit`.
/// Every case in Tests/fixtures/text-rules/dates.json must pass, on every platform.
public enum Dates {
    public static func apply(_ text: String) -> String {
        let ns = text as NSString
        var out = "", copied = 0
        // A date starts at a word that does not follow a letter, digit or dot.
        for start in wordStart.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
        where start >= copied {
            let rest = NSRange(location: start, length: ns.length - start)
            for (rx, monthFirst) in [(dayFirst, false), (monthFirst, true)] {
                // The first match is checked as a whole: "twenty ninth of February twenty twenty five" stays.
                guard let m = rx.firstMatch(in: text, options: [.anchored, .withTransparentBounds], range: rest),
                      let date = convert(m, ns, monthFirst: monthFirst) else { continue }
                out += ns.substring(with: NSRange(location: copied, length: start - copied)) + date
                copied = NSMaxRange(m.range)
                break
            }
        }
        return out + ns.substring(from: copied)
    }

    static func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
    static let enOrdinals = words("first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth "
                                  + "thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth")
    static let enNumbers = words("one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
                                 + "fifteen sixteen seventeen eighteen nineteen")
    static let deNumbers = words("ein zwei drei vier fünf sechs sieben acht neun zehn elf zwölf dreizehn vierzehn "
                                 + "fünfzehn sechzehn siebzehn achtzehn neunzehn")

    static let enOrd: [String: Int] = {
        var d = Dictionary(uniqueKeysWithValues: enOrdinals.enumerated().map { ($1, $0 + 1) })
        d["twentieth"] = 20; d["thirtieth"] = 30; d["thirty first"] = 31
        for (i, u) in enOrdinals.prefix(9).enumerated() { d["twenty \(u)"] = 21 + i }
        return d
    }()
    /// 1 to 99 in words, with tens and units apart: "twenty six".
    static let enCard: [String: Int] = {
        var d = Dictionary(uniqueKeysWithValues: enNumbers.enumerated().map { ($1, $0 + 1) })
        for (i, t) in words("twenty thirty forty fifty sixty seventy eighty ninety").enumerated() {
            d[t] = 20 + 10 * i
            for (j, u) in enNumbers.prefix(9).enumerated() { d["\(t) \(u)"] = 21 + 10 * i + j }
        }
        return d
    }()
    /// 1 to 99 in words, one word: "sechsundzwanzig".
    static let deCard: [String: Int] = {
        var d = Dictionary(uniqueKeysWithValues: deNumbers.enumerated().map { ($1, $0 + 1) })
        d["eins"] = 1
        for (i, t) in words("zwanzig dreißig vierzig fünfzig sechzig siebzig achtzig neunzig").enumerated() {
            d[t] = 20 + 10 * i
            for (j, u) in deNumbers.prefix(9).enumerated() { d["\(u)und\(t)"] = 21 + 10 * i + j }
        }
        return d
    }()
    /// German ordinal stems; the word adds -e, -er, -en, -es or -em.
    static let deOrdStem: [String: Int] = {
        let stems = words("erst zweit dritt viert fünft sechst siebt acht neunt zehnt elft zwölft dreizehnt vierzehnt "
                          + "fünfzehnt sechzehnt siebzehnt achtzehnt neunzehnt")
        var d = Dictionary(uniqueKeysWithValues: stems.enumerated().map { ($1, $0 + 1) })
        d["siebent"] = 7; d["zwanzigst"] = 20; d["dreißigst"] = 30; d["einunddreißigst"] = 31
        for (i, u) in deNumbers.prefix(9).enumerated() { d["\(u)undzwanzigst"] = 21 + i }
        return d
    }()
    static let months: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,
        "januar": 1, "februar": 2, "märz": 3, "mai": 5, "juni": 6, "juli": 7, "oktober": 10, "dezember": 12,
    ]

    /// Case, hyphens and the ASCII spellings of umlauts and ß.
    static func fold(_ s: String) -> String {
        [("-", " "), ("ae", "ä"), ("oe", "ö"), ("ue", "ü"), ("ss", "ß")]
            .reduce(s.lowercased()) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
    /// Longest first, so "twenty six" wins over "twenty"; a hyphen equals a space.
    static func alt<S: Sequence<String>>(_ words: S) -> String {
        words.sorted { $0.count > $1.count }.map { $0.replacingOccurrences(of: " ", with: "[ -]") }.joined(separator: "|")
    }
    static func umlauts(_ p: String) -> String {
        [("ä", "(?:ä|ae)"), ("ö", "(?:ö|oe)"), ("ü", "(?:ü|ue)"), ("ß", "(?:ß|ss)")]
            .reduce(p) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    static let (dayFirst, monthFirst, wordStart): (NSRegularExpression, NSRegularExpression, NSRegularExpression) = {
        let enOrdRe = alt(enOrd.keys)
        let deOrd = umlauts("(?:\(alt(deOrdStem.keys)))(?:er|en|es|em|e)")
        let notTens = "(?<!twenty )(?<!twenty-)(?<!thirty )(?<!thirty-)"  // in "twenty ninth" the day is 29, never 9
        let dayWord = "(?:\(notTens)(?:\(enOrdRe))|\(deOrd))"
        let dayDigit = "(?:[0-9]{1,2}(?:st|nd|rd|th)|[0-9]{1,2}\\.|[0-9]{1,2})"
        let month = umlauts(alt(months.keys))
        let enTens = alt(enCard.filter { $0.value >= 10 }.keys)
        let enYear = "(?:(?:twenty|nineteen)[ -](?:oh[ -](?:\(alt(enNumbers.prefix(9))))|\(enTens))"
            + "|two thousand(?:(?: and)? (?:\(alt(enCard.keys))))?)"
        let deYear = umlauts("(?:(?:zweitausend|neunzehnhundert)(?:[ ]?(?:und)?[ ]?(?:\(alt(deCard.keys))))?)")
        // A short year only before punctuation or the end: "July fourth twenty six people" is a count.
        let short = umlauts("(?:[0-9]{2}|\(enTens)|\(alt(deCard.filter { $0.value >= 10 }.keys)))") + "(?=[.,;:!?)]|$)"
        let year = "(?:,? (?<year>[0-9]{4}|\(enYear)|\(deYear)|\(short)))?(?!\\w)(?<dot>\\.)?"
        let b = "(?<![\\w.])"
        func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }
        return (rx("\(b)(?:the )?(?<day>\(dayWord)|\(dayDigit))(?<of> of)? (?<month>\(month))\(year)"),
                rx("\(b)(?<month>\(month))(?: the)? (?<day>(?:\(enOrdRe))|[0-9]{1,2}(?:st|nd|rd|th)?)\(year)"),
                rx("\(b)\\w"))
    }()

    static func convert(_ m: NSTextCheckingResult, _ ns: NSString, monthFirst: Bool) -> String? {
        func group(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let monthText = group("month"), let mo = months[fold(monthText)], let dayText = group("day"),
              let d = dayValue(dayText) else { return nil }
        if monthFirst, fold(monthText) == "may", monthText != "May" { return nil }  // "you may first want to" is the verb
        let yearText = group("year")
        let yy = yearText.flatMap(yearValue)
        if yearText != nil, yy == nil { return nil }
        guard valid(d, mo, year: yearText.map { fullYear($0, yy!) }) else { return nil }
        // "Fourth of July" without a year is the holiday's name (docs/text-rules.md, decision).
        if !monthFirst, yearText == nil, d == 4, mo == 7, group("of") != nil { return nil }
        guard let yy else { return String(format: "%02d.%02d.", d, mo) }  // a following "." is the date's own dot
        return String(format: "%02d.%02d.%02d", d, mo, yy) + (group("dot") ?? "")
    }

    static func dayValue(_ s: String) -> Int? {
        let digits = s.prefix { $0.isASCII && $0.isNumber }  // "26", "26th", "26."
        if !digits.isEmpty { return Int(digits) }
        let f = fold(s)
        if let n = enOrd[f] { return n }
        for end in ["er", "en", "es", "em", "e"] where f.hasSuffix(end) {
            if let n = deOrdStem[String(f.dropLast(end.count))] { return n }
        }
        return nil
    }

    static func yearValue(_ s: String) -> Int? {
        if let n = Int(s) { return n % 100 }
        let f = fold(s)
        if let n = enCard[f] ?? deCard[f] { return n }
        for head in ["zweitausend", "neunzehnhundert"] where f.hasPrefix(head) {
            var rest = f.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("und") { rest = rest.dropFirst(3).trimmingCharacters(in: .whitespaces) }
            return rest.isEmpty ? 0 : deCard[rest]
        }
        let w = words(f)
        if w.starts(with: ["two", "thousand"]) {
            let rest = w.dropFirst(2).filter { $0 != "and" }.joined(separator: " ")
            return rest.isEmpty ? 0 : enCard[rest]
        }
        return enCard[w.dropFirst(w.dropFirst().first == "oh" ? 2 : 1).joined(separator: " ")]
    }

    static func fullYear(_ s: String, _ yy: Int) -> Int {
        if s.count == 4, let n = Int(s) { return n }
        let f = fold(s)
        return (f.hasPrefix("nineteen") || f.hasPrefix("neunzehn") ? 1900 : 2000) + yy
    }

    /// 29 February needs a leap year only when a year is given.
    static func valid(_ d: Int, _ m: Int, year: Int?) -> Bool {
        var days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        if m == 2, let y = year, !(y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) { days = 28 }
        return (1...days).contains(d)
    }
}
