import Foundation

/// F26: words learned from the user's own fix of a pasted dictation. The pasted words are aligned with the same span
/// of the field read later (token Levenshtein), and each misheard word or short phrase the user replaced becomes a
/// dictionary pair. Conservative on purpose: a learned pair rewrites every later dictation, so anything that looks
/// like a change of mind rather than a fix of what was heard learns nothing.
public enum AutoLearn {
    /// A word or phrase as pasted and as the user corrected it. A case-only fix is a casing entry.
    public struct Pair: Equatable, Sendable {
        public var heard: String
        public var corrected: String
        public init(heard: String, corrected: String) { self.heard = heard; self.corrected = corrected }
        public var isCasing: Bool { heard.lowercased() == corrected.lowercased() }
        /// The dictionary entry: `heard => corrected`, or for a case fix the word itself with its new casing.
        public var entry: Vocabulary.Entry {
            isCasing ? Vocabulary.Entry(spoken: corrected, written: corrected) : Vocabulary.Entry(spoken: heard, written: corrected)
        }
    }

    /// At most this many pairs are learned from one dictation.
    public static let maxPairs = 3
    /// A fix spans at most this many words on either side ("cooper netties" => "Kubernetes").
    public static let maxPhraseWords = 3
    /// Longer than this, a "word" is a sentence in a script without spaces, not a misheard word.
    public static let maxPhraseLength = 24
    /// A pair whose letters differ more than this (edit distance over the longer one) is a different word, not a
    /// mishearing of it: "send" => "share" is 0.8, "jon" => "John" 0.25, "Pavel" => "Pablo" 0.6.
    public static let maxCharacterDistance = 0.6

    /// Our own short list of words too common to learn: a fix of "their" to "there" is grammar, not hearing.
    public static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "too", "in", "on", "at", "by", "for", "with", "from",
        "as", "into", "about", "is", "are", "was", "were", "be", "been", "am", "it", "its", "it's", "i", "i'm", "me",
        "my", "we", "our", "us", "you", "your", "you're", "he", "she", "him", "her", "his", "they", "them", "their",
        "there", "they're", "this", "that", "these", "those", "not", "no", "yes", "so", "do", "does", "did", "done",
        "have", "has", "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must", "just",
        "then", "than", "very", "up", "out", "what", "which", "who", "whom", "how", "when", "where", "why", "all",
        "any", "some", "ok", "okay", "oh", "um", "uh", "also", "here", "hi", "hey", "well", "now", "get", "got",
        "der", "die", "das", "und", "ist", "ich", "du", "ein", "eine", "nicht", "zu", "mit", "den", "dem", "es",
        "wir", "sie", "er", "ja", "nein", "auf", "für", "von",
    ]

    /// The pasted span in the field's text now: the field was `before` + pasted + `after` at paste time, so the span
    /// is what sits between them. nil when the text before or after it changed (the user edited elsewhere, sent the
    /// message, or another field is read): then nothing can be told about the span.
    public static func span(in field: String, before: String, after: String) -> String? {
        let t = Array(field.utf16), b = Array(before.utf16), a = Array(after.utf16)
        guard t.count >= b.count + a.count, t.starts(with: b), t.suffix(a.count).elementsEqual(a) else { return nil }
        return String(decoding: t[b.count ..< t.count - a.count], as: UTF16.self)
    }

    /// What `pasted` taught when the user turned it into `edited`. `before` is the field's text before the span, so
    /// a word that starts a sentence is told apart from a name. Text typed before or after the pasted words, pure
    /// deletions and insertions learn nothing; a rewrite (more than half of the words changed) learns nothing.
    public static func learn(pasted: String, edited: String, before: String = "") -> [Pair] {
        let old = tokens(pasted), new = tokens(edited)
        guard !old.isEmpty, old != new else { return [] }
        var ops = align(old.map(\.core), new.map(\.core))
        // Typed before or after the pasted words: not a fix of them.
        while ops.first?.kind == .insert { ops.removeFirst() }
        while ops.last?.kind == .insert { ops.removeLast() }
        let changes = ops.filter { $0.kind != .match }.count
        guard changes > 0, changes == 1 || changes * 2 <= old.count else { return [] }

        let keptWords = Set(ops.filter { $0.kind == .match }.compactMap { $0.old.map { old[$0].core.lowercased() } })
        var pairs: [Pair] = []
        for block in blocks(ops) {
            let heardTokens = block.compactMap(\.old), correctedTokens = block.compactMap(\.new)
            guard !heardTokens.isEmpty, !correctedTokens.isEmpty,  // a pure deletion or insertion
                  heardTokens.count <= maxPhraseWords, correctedTokens.count <= maxPhraseWords else { continue }
            let heard = heardTokens.map { old[$0].core }.joined(separator: " ")
            let corrected = correctedTokens.map { new[$0].core }.joined(separator: " ")
            let pair = Pair(heard: heard, corrected: corrected)
            // The same word left as it was elsewhere in the text: the user did not fix it everywhere, so it is not a
            // word the model always gets wrong.
            guard !keptWords.contains(heard.lowercased()) else { continue }
            let startsSentence = heardTokens.first == 0 ? startsSentence(before) : old[heardTokens[0] - 1].endsSentence
            guard learnable(pair, startsSentence: startsSentence), !pairs.contains(pair) else { continue }
            pairs.append(pair)
        }
        return Array(pairs.prefix(maxPairs))
    }

    /// The filters on one pair.
    static func learnable(_ p: Pair, startsSentence: Bool) -> Bool {
        let sides = [p.heard, p.corrected]
        if sides.contains(where: { $0.contains(where: \.isNumber) }) { return false }
        if sides.contains(where: { $0.count > maxPhraseLength || $0.filter(\.isLetter).count < 2 }) { return false }
        if sides.contains(where: { $0.count == 1 && isCJK($0) }) { return false }
        if sides.contains(where: { $0.lowercased().split(separator: " ").allSatisfy { stopwords.contains(String($0)) } }) { return false }
        if p.isCasing {
            // Only a casing a dictionary entry should keep: an inner capital (GitHub, iPhone, NASA), or a capital
            // on a name inside a sentence. Lowering a word, or capitalizing a sentence start, is style.
            let inner = p.corrected.split(separator: " ").contains { $0.dropFirst().contains(where: \.isUppercase) }
            let capitalized = p.corrected.first?.isUppercase == true && p.heard.first?.isLowercase == true
            return inner || (capitalized && !startsSentence)
        }
        return ratio(p.heard, p.corrected).map { $0 <= maxCharacterDistance } ?? false
    }

    // MARK: alignment

    struct Token: Equatable {
        var core: String          // the word without the punctuation around it
        var endsSentence: Bool
    }

    /// Words split at whitespace, compared without the punctuation around them, so "jon," and "jon." match.
    static func tokens(_ s: String) -> [Token] {
        s.split(whereSeparator: \.isWhitespace).compactMap { w in
            let core = w.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !core.isEmpty else { return nil }
            return Token(core: core, endsSentence: w.last.map { ".!?:".contains($0) } ?? false)
        }
    }

    static func startsSentence(_ before: String) -> Bool {
        guard let last = before.last(where: { !$0.isWhitespace || $0.isNewline }) else { return true }
        return last.isNewline || ".!?:".contains(last)
    }

    enum Kind { case match, substitute, delete, insert }
    struct Op: Equatable { var kind: Kind; var old: Int?; var new: Int? }

    /// Token Levenshtein with its path. A substitution costs less the closer the two words are ("jon" lines up with
    /// "John", not with "noon" typed after it), and two unlike words cost as much as a deletion plus an insertion.
    static func align(_ a: [String], _ b: [String]) -> [Op] {
        func cost(_ x: String, _ y: String) -> Double {
            if x == y { return 0 }
            guard let r = ratio(x, y), r <= maxCharacterDistance else { return 2 }
            return 0.1 + r  // a case fix still costs something, so an exact match always wins
        }
        var d = Array(repeating: Array(repeating: 0.0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = Double(i) }
        for j in 0...b.count { d[0][j] = Double(j) }
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                d[i][j] = min(d[i - 1][j - 1] + cost(a[i - 1], b[j - 1]), d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
        func same(_ x: Double, _ y: Double) -> Bool { abs(x - y) < 1e-9 }
        var ops: [Op] = [], i = a.count, j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, same(d[i][j], d[i - 1][j - 1] + cost(a[i - 1], b[j - 1])) {
                ops.append(Op(kind: a[i - 1] == b[j - 1] ? .match : .substitute, old: i - 1, new: j - 1)); i -= 1; j -= 1
            } else if i > 0, same(d[i][j], d[i - 1][j] + 1) {
                ops.append(Op(kind: .delete, old: i - 1, new: nil)); i -= 1
            } else {
                ops.append(Op(kind: .insert, old: nil, new: j - 1)); j -= 1
            }
        }
        return ops.reversed()
    }

    /// Letter edit distance over the longer word, case ignored; nil for words without letters.
    static func ratio(_ x: String, _ y: String) -> Double? {
        let a = Array(x.lowercased().filter(\.isLetter)), b = Array(y.lowercased().filter(\.isLetter))
        guard !a.isEmpty, !b.isEmpty else { return nil }
        return Double(distance(a, b)) / Double(max(a.count, b.count))
    }

    /// Runs of changes between matching words.
    static func blocks(_ ops: [Op]) -> [[Op]] {
        var out: [[Op]] = [], run: [Op] = []
        for op in ops {
            if op.kind == .match { if !run.isEmpty { out.append(run); run = [] } } else { run.append(op) }
        }
        return run.isEmpty ? out : out + [run]
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cur = row[j]
                row[j] = min(prev + (a[i - 1] == b[j - 1] ? 0 : 1), row[j] + 1, row[j - 1] + 1)
                prev = cur
            }
        }
        return row[b.count]
    }

    static func isCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
            || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
}
