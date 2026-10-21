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
            while let last = text.last, sentenceEnd.contains(last) { text.removeLast() }
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
