import Foundation
import NaturalLanguage

/// Fits dictated text to the text around the cursor (docs/re/insertion-context.md 2.2 and 2.5):
/// spacing, first-letter case and trailing punctuation. Only the cursor's line counts: the last line
/// of `before` and the first line of `after`. `selected` is the text the paste replaces.
public enum InsertionRules {
    static let sentenceEnd: Set<Character> = [".", "!", "?", "…"]
    static let opening: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "@", "#"]
    /// A quote or bracket that closes after a sentence's end: `(See above.) |` is a sentence start.
    static let closing: Set<Character> = [")", "]", "}", "\"", "'", "”", "’", "»"]
    /// The space before a following word is non-breaking, so apps that trim trailing ASCII spaces keep it.
    public static let nbsp = "\u{00A0}"
    /// A final "DD.MM." with a real day and month: its dot is the date's. "It costs 19.99." ends in a price.
    static let dayMonthEnd = #"(?<![\w.])(?:0[1-9]|[12][0-9]|3[01])\.(?:0[1-9]|1[0-2])\.$"#

    public static func fit(_ dictated: String, before: String, after: String, selected: String = "") -> String {
        var text = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let before = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        let after = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? ""
        let sel = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = String(selected.prefix(while: \.isWhitespace))
        let trail = sel.isEmpty ? "" : String(selected.reversed().prefix(while: \.isWhitespace).reversed())

        let prev = before.last(where: { !$0.isWhitespace && !closing.contains($0) })
        let midSentence = prev.map { !sentenceEnd.contains($0) } ?? false

        // Case: the selection's first letter when it has one that says something (not "I" or an acronym),
        // else lowercase mid-sentence. Our own "I", acronyms and names are never lowercased.
        let lowers = { keepsLowercase(firstWord(text)) && !isName(text, after: before) }
        if let f = sel.first(where: \.isLetter), keepsLowercase(firstWord(sel)) {
            if f.isUppercase { text = text.prefix(1).uppercased() + text.dropFirst() }
            else if lowers() { text = text.prefix(1).lowercased() + text.dropFirst() }
        } else if midSentence, lowers() {
            text = text.prefix(1).lowercased() + text.dropFirst()
        }

        // Sentence end: match the selection's, else drop ours when the sentence goes on after the cursor: the next
        // character is lowercase, a comma-like mark or the sentence's own end, or any word follows mid-sentence.
        let next = after.drop(while: \.isWhitespace)
        let continues = next.first.map {
            $0.isLowercase || ",;:".contains($0) || sentenceEnd.contains($0) || (midSentence && startsWord(next))
        } ?? false
        if let end = sel.last, sentenceEnd.contains(end) {
            if let last = text.last, !sentenceEnd.contains(last) { text.append(end) }
        } else if !sel.isEmpty || continues {
            // A final "DD.MM." keeps its dot: it is the date's, not the sentence's (docs/text-rules.md).
            while let last = text.last, sentenceEnd.contains(last),
                  text.range(of: dayMonthEnd, options: .regularExpression) == nil {
                text.removeLast()
            }
        }

        if !lead.isEmpty { text = lead + text }
        else if let c = before.last, !c.isWhitespace, !opens(before) { text = " " + text }
        if !trail.isEmpty { text += trail }
        else if startsWord(after) { text += nbsp }
        return text
    }

    /// A word, or a bracket or quote that opens one: `|"hello" to me` and `|(briefly) John` as much as `|John`.
    static func startsWord(_ s: Substring) -> Bool {
        guard let c = s.first else { return false }
        if c.isLetter || c.isNumber || "([{“‘«".contains(c) { return true }
        return "\"'".contains(c) && (s.dropFirst().first.map { $0.isLetter || $0.isNumber } ?? false)
    }

    /// The cursor is right after an opening mark. A straight quote right after a word closes it: `"Stop."|`.
    static func opens(_ before: Substring) -> Bool {
        guard let c = before.last, opening.contains(c) else { return false }
        return !"\"'".contains(c) || (before.dropLast().last?.isWhitespace ?? true)
    }

    /// A name the model capitalised at the start ("I think |John will…"), as the tagger reads it in the cursor's
    /// sentence. A word that is a verb, adjective and so on once lowercased ("Wait", "Quick") is not one. On 2,800
    /// made-up fragments this kept 78% of names, and the capital of 0.6% of common words; words that are also
    /// names ("Bill the client") keep it more often. ponytail: the personal dictionary (Vocabulary, F39) could
    /// settle those.
    static func isName(_ text: String, after before: Substring) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        func tag(_ t: String, _ scheme: NLTagScheme) -> NLTag? {
            let s = before + " " + t
            tagger.string = s
            return tagger.tag(at: s.index(s.endIndex, offsetBy: -t.count), unit: .word, scheme: scheme).0
        }
        guard let name = tag(text, .nameType), [.personalName, .placeName, .organizationName].contains(name) else { return false }
        let lower = tag(text.prefix(1).lowercased() + text.dropFirst(), .lexicalClass)
        return lower == nil || lower == .noun || lower == .otherWord
    }

    static func firstWord(_ s: String) -> Substring {
        s.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
    }

    /// False for "I", "I'm" and acronyms like "API".
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
/// `SmartCleanup` (CleanupModel.swift) runs the local cleanup model after this.
public enum Cleanup {
    public static func apply(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsUpper = s.first?.isUppercase ?? false
        // A filler between commas was a pause, so both commas go with it ("we should, uh, push" → "we should push").
        // ponytail: "apples, um, pears" loses its list comma too.
        s = s.replacingOccurrences(of: #"(?i),\s*(?:u+m+|u+h+|uhm|erm|hmm+)\s*,"#, with: "", options: .regularExpression)
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
/// Every case in Tests/fixtures/text-rules/dates.json must pass, on every platform. It reads words the way
/// `dates` in windows/crates/core/src/text.rs does, so the platforms stay alike.
public enum Dates {
    public static func apply(_ text: String) -> String {
        let w = Words(text)
        var out = String.UnicodeScalarView(), copied = 0, i = 0
        while i < w.at.count {
            guard let f = w.date(i) else { i += 1; continue }
            if let date = f.date {
                out.append(contentsOf: w.s[copied..<w.at[i].0])
                out.append(contentsOf: date.unicodeScalars)
                copied = f.end
            }
            i = f.next
        }
        out.append(contentsOf: w.s[copied...])
        return String(out)
    }

    static func list(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
    static let monthsEn = list("january february march april may june july august september october november december")
    static let monthsDe = list("januar februar märz april mai juni juli august september oktober november dezember")
    static let units = list("one two three four five six seven eight nine")
    static let teens = list("ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen")
    static let tens = list("twenty thirty forty fifty sixty seventy eighty ninety")
    static let ordinals = list("first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth "
                               + "thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth")
    static let einer = list("ein zwei drei vier fünf sechs sieben acht neun")
    static let zehner = list("zehn elf zwölf dreizehn vierzehn fünfzehn sechzehn siebzehn achtzehn neunzehn")
    static let ziger = list("zwanzig dreißig vierzig fünfzig sechzig siebzig achtzig neunzig")
    static let ordnung = list("erst zweit dritt viert fünft sechst siebt acht neunt")
    /// What may follow a short year: `.` `;` `:` `!` `?` `)` and closing quotes ("July 26, 26", „... sechsundzwanzig“).
    static let ends: Set<Unicode.Scalar> = Set(".;:!?)\"'’”“»«".unicodeScalars)

    /// 1 for the first entry of `list`.
    static func pos(_ list: [String], _ w: some StringProtocol) -> Int? { list.firstIndex { $0 == w }.map { $0 + 1 } }
    static func month(_ w: String) -> Int? { pos(monthsEn, w) ?? pos(monthsDe, w) }

    /// English 1 to 99: "six", "twelve", "twenty six".
    static func enNumber(_ p: String) -> Int? {
        let parts = p.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            guard let t = pos(tens, parts[0]), let u = pos(units, parts[1]) else { return nil }
            return t * 10 + 10 + u
        }
        return pos(units, p) ?? pos(teens, p).map { $0 + 9 } ?? pos(tens, p).map { $0 * 10 + 10 }
    }

    /// English day 1 to 31: "first", "twentieth", "twenty sixth".
    static func enOrdinal(_ p: String) -> Int? {
        let parts = p.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            if parts[0] == "twenty" { return pos(Array(ordinals.prefix(9)), parts[1]).map { $0 + 20 } }
            return parts[0] == "thirty" && parts[1] == "first" ? 31 : nil
        }
        return pos(ordinals, p) ?? ["twentieth": 20, "thirtieth": 30][p]
    }

    /// German 1 to 99 as one word: "eins", "zwölf", "sechsundzwanzig".
    static func deNumber(_ w: some StringProtocol) -> Int? {
        if let r = w.range(of: "und") {
            guard let t = pos(ziger, w[r.upperBound...]), let e = pos(einer, w[..<r.lowerBound]) else { return nil }
            return t * 10 + 10 + e
        }
        if w == "eins" { return 1 }
        return pos(einer, w) ?? pos(zehner, w).map { $0 + 9 } ?? pos(ziger, w).map { $0 * 10 + 10 }
    }

    /// German day as one word with its ending: "erste", "siebten", "zwölfter", "sechsundzwanzigsten".
    static func deOrdinal(_ w: String) -> Int? {
        guard let end = ["er", "en", "es", "em", "e"].first(where: w.hasSuffix) else { return nil }
        let stem = w.dropLast(end.count)
        if stem == "siebent" { return 7 }
        if let n = pos(ordnung, stem) { return n }
        if stem.hasSuffix("t"), let n = pos(zehner, stem.dropLast()) { return n + 9 }
        if stem.hasSuffix("st"), let n = deNumber(stem.dropLast(2)), n >= 20 { return n }
        return nil
    }

    /// zweitausend, zweitausendsechsundzwanzig, zweitausend sechsundzwanzig, zweitausendundfünf, neunzehnhundert...
    static func deYear(_ p: String) -> Int? {
        let all = p.replacingOccurrences(of: " ", with: "")
        guard let head = ["zweitausend", "neunzehnhundert"].first(where: all.hasPrefix) else { return nil }
        let rest = all.dropFirst(head.count)
        if rest.isEmpty { return 0 }
        return deNumber(rest.hasPrefix("und") ? rest.dropFirst(3) : rest)
    }

    /// "26", "26th" or "1st": the day, and whether it is bare digits (only those take the German "26.").
    static func digitDay(_ w: String) -> (Int, Bool)? {
        let b = Array(w.utf8)
        let n = b.firstIndex { !(48...57).contains($0) } ?? b.count
        guard (1...2).contains(n), ["", "st", "nd", "rd", "th"].contains(String(decoding: b[n...], as: UTF8.self))
        else { return nil }
        return (Int(String(decoding: b[..<n], as: UTF8.self))!, n == b.count)
    }

    static func digits(_ w: String, _ n: Int) -> Int? {
        w.utf8.count == n && w.utf8.allSatisfy { (48...57).contains($0) } ? Int(w) : nil
    }

    /// A date found at a word: its numbers, the word after it, and where it ends in `s`. `date` is nil for a
    /// phrase that stays as it is, as a whole: its month starts no other date.
    struct Found { let date: String?, next: Int, end: Int }
    typealias Year = (yy: Int, full: Int, next: Int)

    /// The text as words (runs of `\w`) and what is between them, by Unicode scalar like the Rust `char`s.
    struct Words {
        let s: [Unicode.Scalar]
        let at: [(Int, Int)]
        /// Word `i` in lowercase, with ae, oe, ue and ss read as ä, ö, ü and ß.
        let folded: [String]

        init(_ text: String) {
            s = Array(text.unicodeScalars)
            var at: [(Int, Int)] = [], i = 0
            while i < s.count {
                guard Words.isWord(s[i]) else { i += 1; continue }
                let a = i
                while i < s.count, Words.isWord(s[i]) { i += 1 }
                at.append((a, i))
            }
            self.at = at
            let s = s
            folded = at.map { a, b in
                [("ae", "ä"), ("oe", "ö"), ("ue", "ü"), ("ss", "ß")].reduce(Words.string(s[a..<b]).lowercased()) {
                    $0.replacingOccurrences(of: $1.0, with: $1.1)
                }
            }
        }

        /// Regex `\w`, as Rust's `is_alphanumeric() || '_'`.
        static func isWord(_ c: Unicode.Scalar) -> Bool {
            c.properties.isAlphabetic || c.properties.numericType != nil || c == "_"
        }
        static func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }
        static func string(_ s: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(s)) }

        /// "" past the end.
        func word(_ i: Int) -> String { i < folded.count ? folded[i] : "" }

        /// The text after word `i` up to the next word, or to the end after the last one.
        func gap(_ i: Int) -> String {
            guard i < at.count else { return "" }
            return Words.string(s[at[i].1..<(i + 1 < at.count ? at[i + 1].0 : s.count)])
        }

        /// A hyphen equals a space inside a spoken number.
        func spaced(_ i: Int) -> Bool { [" ", "-"].contains(gap(i)) }

        /// The longest run of up to `max` spaced words from `i` that `f` reads: its value and length.
        func longest(_ i: Int, _ max: Int, _ f: (String) -> Int?) -> (Int, Int)? {
            for n in stride(from: max, through: 1, by: -1) where i + n <= at.count && (i..<i + n - 1).allSatisfy(spaced) {
                if let v = f((i..<i + n).map(word).joined(separator: " ")) { return (v, n) }
            }
            return nil
        }

        func date(_ i: Int) -> Found? {
            let a = at[i].0
            if a > 0, s[a - 1] == "." { return nil }  // inside "26.07.26": already numbers
            if a > 1, ",:/-".unicodeScalars.contains(s[a - 1]), Words.isDigit(s[a - 2]) {
                return nil  // inside a number: "10:30 July 4th"
            }
            return dayFirst(i) ?? monthFirst(i)
        }

        /// `[the] DAY [of] MONTH [,] [YEAR]`
        func dayFirst(_ i: Int) -> Found? {
            let the = word(i) == "the" && gap(i) == " "
            let d = i + (the ? 1 : 0)
            // A spelled day is the whole number: in "twenty ninth" the day is 29, never "ninth", and "forty first",
            // "hundred and first" and "sechs und zwanzigsten" are no day. Cleanup leaves "twenty, ninth" from
            // "twenty, uh, ninth".
            let big = ["hundred", "thousand"]
            let numberBefore = d > 0 && [" ", "-", ", "].contains(gap(d - 1)) && (pos(tens, word(d - 1)) != nil
                || big.contains(word(d - 1)) || (word(d - 1) == "and" && d > 1 && spaced(d - 2) && big.contains(word(d - 2))))
            let undBefore = d > 1 && word(d - 1) == "und" && gap(d - 1) == " " && gap(d - 2) == " "
                && pos(einer, word(d - 2)) != nil
            let day: Int, n: Int, bare: Bool, en: Bool
            if !numberBefore, let r = longest(d, 2, enOrdinal) {
                (day, n, bare, en) = (r.0, r.1, false, true)
            } else if !undBefore, let v = deOrdinal(word(d)) {
                (day, n, bare, en) = (v, 1, false, false)
            } else {
                guard let r = digitDay(word(d)) else { return nil }
                (day, n, bare, en) = (r.0, 1, r.1, false)
            }
            let g = gap(d + n - 1)
            let dot = bare && g == ". "
            guard g == " " || dot else { return nil }
            // "of" never ends a phrase, so a comma after it is a dropped filler's: "the first of, um, March".
            let of = word(d + n) == "of" && [" ", ", "].contains(gap(d + n))
            if en && !of { return nil }  // "my first April", "this is my third September"
            if bare && of { return nil }  // "week 2 of March", "Chapter 3 of May's report" count, they are no day
            let m = d + n + (of ? 1 : 0)
            guard let mo = month(word(m)) else { return nil }
            if gap(m).hasPrefix("-") { return nil }  // "die erste Juli-Woche" is a week
            if dot && pos(monthsDe, word(m)) == nil {
                return nil  // the German "26." needs a German month: "version 2. March is next", "5. May I ask"
            }
            if !of && ["may", "march"].contains(word(m)) && !capital(m) {
                return nil  // "the second may be better", "the first march was long"
            }
            let keep = Found(date: nil, next: m + 1, end: 0)
            let year = self.year(m)
            if of && year == nil && (day, mo) == (4, 7) { return keep }  // "Happy Fourth of July!" is the holiday's name
            return found(day, mo, m, year) ?? keep  // "the 31st of February" stays, and "February 15" in it is no date
        }

        /// `MONTH [the] DAY [,] [YEAR]`, with an English month and an English or digit day. German puts the day
        /// first, so "Mai 2" in "I met Mai 2 weeks ago" is no date.
        func monthFirst(_ i: Int) -> Found? {
            guard let mo = pos(monthsEn, word(i)) else { return nil }
            if word(i) == "may" && !capital(i) { return nil }  // "you may first want to"
            guard gap(i) == " " else { return nil }
            let the = word(i + 1) == "the" && gap(i + 1) == " "
            let d = i + 1 + (the ? 1 : 0)
            let day: Int, n: Int
            if let r = longest(d, 2, enOrdinal) {
                if gap(d + r.1 - 1).hasPrefix("-") { return nil }  // "In March second-quarter numbers dropped"
                (day, n) = r
            } else if joined(d) {
                return nil  // "June 26.07.2026", "July 10:30", "March 3-5", "July 26%"
            } else {
                guard let r = digitDay(word(d)) else { return nil }
                (day, n) = (r.0, 1)
            }
            let year = self.year(d + n - 1)
            let last = year.map { $0.next - 1 } ?? d + n - 1
            if the && mo == 5 && gap(last) == " " && word(last + 1) == "be" {
                return nil  // "May the fourth be with you" is a wish
            }
            return found(day, mo, d + n - 1, year)
        }

        /// The year after word `last` (a comma between is fine): its last two digits, the full year and the
        /// word after it.
        func year(_ last: Int) -> Year? {
            guard [" ", ", "].contains(gap(last)) else { return nil }
            let y = last + 1, w = word(y)
            let yy: Int, full: Int, n: Int
            if let v = Dates.digits(w, 4) {
                guard (1900...2099).contains(v) else { return nil }  // "On May 5th 1350 visitors came" is a count
                (yy, full, n) = (v % 100, v, 1)
            } else {
                let century = w.hasPrefix("nineteen") || w.hasPrefix("neunzehn") ? 1900 : 2000
                guard let r = spokenYear(y, w) else { return nil }
                (yy, full, n) = (r.0, century + r.0, r.1)
            }
            // A year ending in 00 is also a round count: "On July 4th two thousand people marched". And a year
            // never stops inside a hyphenated word: "nineteen twenty-first" is not 1920.
            let l = y + n - 1
            return (yy != 0 || ends(l)) && !gap(l).hasPrefix("-") ? (yy, full, y + n) : nil
        }

        /// A spelled or two-digit year at word `y` (`w`): its last two digits and its length in words.
        func spokenYear(_ y: Int, _ w: String) -> (Int, Int)? {
            if w == "nineteen" && spaced(y) && word(y + 1) == "hundred" { return (0, 2) }
            // twenty twenty-six, nineteen ninety nine, twenty oh nine
            if (w == "twenty" || w == "nineteen") && spaced(y) {
                if word(y + 1) == "oh" && spaced(y + 1), let u = pos(units, word(y + 2)) { return (u, 3) }
                if let r = longest(y + 1, 2, enNumber), r.0 >= 10 { return (r.0, 1 + r.1) }
            }
            // two thousand, two thousand five, two thousand and twenty six
            if w == "two" && spaced(y) && word(y + 1) == "thousand" {
                let and = spaced(y + 1) && word(y + 2) == "and" && spaced(y + 2) ? 1 : 0
                guard spaced(y + 1), let r = longest(y + 2 + and, 2, enNumber) else { return (0, 2) }
                return (r.0, 2 + and + r.1)
            }
            // zweitausend sechs und zwanzig is 2026 as a whole, never 2006
            if let found = longest(y, 4, deYear) { return found }
            // A short year (26, twenty six, sechsundzwanzig) only where `ends`: in "July fourth twenty six people
            // came" it is a count.
            let short = Dates.digits(w, 2).map { ($0, 1) }
                ?? (longest(y, 2, enNumber) ?? deNumber(w).map { ($0, 1) }).flatMap { $0.0 >= 10 ? $0 : nil }
            guard let r = short, ends(y + r.1 - 1) else { return nil }
            return r
        }

        /// The end of the text, or `.` `;` `:` `!` `?` `)` or a quote without a digit right after it, follows word
        /// `k`. A comma does not count: in "May 15, 16, and 17" the 16 is a day, and in "March 5, 10:30" a time.
        func ends(_ k: Int) -> Bool {
            let e = at[k].1
            guard e < s.count else { return true }
            return Dates.ends.contains(s[e]) && !(e + 1 < s.count && Words.isDigit(s[e + 1]))
        }

        /// Word `k` runs on into another number or a sign: only a space, the end, or `,` or what `ends` takes,
        /// without a digit right after it, ends a day. "26.07.2026", "10:30", "3-5", "26/27" and "26%" stay.
        func joined(_ k: Int) -> Bool {
            guard k < at.count, at[k].1 < s.count else { return false }
            let e = at[k].1, c = s[e]
            return !c.properties.isWhitespace
                && (!(c == "," || Dates.ends.contains(c)) || (e + 1 < s.count && Words.isDigit(s[e + 1])))
        }

        /// Word `i` starts with a capital: "May", "MAY".
        func capital(_ i: Int) -> Bool { s[at[i].0].properties.isUppercase }

        /// The date as numbers if it exists, from its fields and its last word before the year.
        func found(_ day: Int, _ mo: Int, _ last: Int, _ year: Year?) -> Found? {
            let leap = { (y: Int) in y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }
            let feb = year.map { leap($0.full) ? 29 : 28 } ?? 29
            guard (1...[31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]).contains(day) else { return nil }
            if let y = year {
                return Found(date: String(format: "%02d.%02d.%02d", day, mo, y.yy), next: y.next, end: at[y.next - 1].1)
            }
            // A "." right after "DD.MM." is the date's own dot.
            let end = at[last].1, dot = end < s.count && s[end] == "." ? 1 : 0
            return Found(date: String(format: "%02d.%02d.", day, mo), next: last + 1, end: end + dot)
        }
    }
}
