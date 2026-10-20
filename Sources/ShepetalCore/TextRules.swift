import Foundation

/// Fits dictated text to the text around the cursor (docs/re/insertion-context.md 2.5):
/// spacing, first-letter case and trailing punctuation.
public enum InsertionRules {
    static let sentenceEnd: Set<Character> = [".", "!", "?"]
    static let opening: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "@", "#"]

    public static func fit(_ dictated: String, before: String, after: String) -> String {
        var text = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // Mid-sentence: lowercase the first letter, unless the word must stay capitalized ("I", "API").
        let lastBefore = before.last(where: { $0 != " " && $0 != "\t" })
        if let c = lastBefore, !c.isNewline, !sentenceEnd.contains(c), keepsLowercase(firstWord(text)) {
            text = text.prefix(1).lowercased() + text.dropFirst()
        }

        // Text follows that continues the sentence: drop our sentence end.
        if let next = after.first(where: { $0 != " " && $0 != "\t" }), next.isLowercase || ",;:".contains(next) {
            while let last = text.last, sentenceEnd.contains(last) { text.removeLast() }
        }

        if let c = before.last, !c.isWhitespace, !opening.contains(c) { text = " " + text }
        if let c = after.first, c.isLetter || c.isNumber { text += " " }
        return text
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
