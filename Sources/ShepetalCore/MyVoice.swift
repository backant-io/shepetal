import Foundation

/// F38 "My voice" (Wispr's UserVoicePreferences): how the user wants their dictation to read, in their own words,
/// and a few samples of their writing. The local cleanup model gets both, the samples as examples, and may then
/// change punctuation, capital letters, contractions and line breaks to match. The word guard still rejects any
/// other change of words, so an answer or a translation still falls back to the rules' text. voice.json, in the
/// owner-only data dir; dictation reads it each time.
public struct MyVoice: Codable, Equatable, Sendable {
    public static let none = MyVoice()
    /// Samples, and characters per sample and for the preferences: what the model's context has room for.
    public static let maxSamples = 3, limit = 400

    public let preferences: String
    public let samples: [String]

    public init(preferences: String = "", samples: [String] = []) {
        self.preferences = Self.cut(preferences)
        self.samples = Array(samples.map(Self.cut).filter { !$0.isEmpty }.prefix(Self.maxSamples))
    }

    public var isEmpty: Bool { preferences.isEmpty && samples.isEmpty }

    /// A missing or unreadable file is no voice. Keeps the file owner-only.
    public static func load(_ url: URL) -> MyVoice {
        guard let data = FileManager.default.contents(atPath: url.path),
              let v = try? JSONDecoder().decode(MyVoice.self, from: data) else { return .none }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return MyVoice(preferences: v.preferences, samples: v.samples)  // the file may be edited by hand
    }

    /// Writes the file as 0600, or removes it when there is no voice.
    public func save(_ url: URL) throws {
        let fm = FileManager.default
        if isEmpty {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard fm.createFile(atPath: url.path, contents: try enc.encode(self), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Trimmed, without the model's control markers ("<|im_end|>", "<think>"), and cut at a word within `limit`.
    /// Removed until none is left: "<|im_<|x|>end|>" is "<|im_end|>" after one pass.
    static func cut(_ s: String) -> String {
        var t = s, before = ""
        while t != before {
            before = t
            t = t.replacingOccurrences(of: #"<\|[^|>]*\|>|</?think>"#, with: "", options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        let head = t.prefix(limit)
        if t[head.endIndex].isWhitespace { return String(head) }
        return head.lastIndex(where: \.isWhitespace).map { String(head[..<$0]) } ?? String(head)
    }

    // MARK: contractions

    /// The text with its contractions spelled out: "don't" is "do not", "I'm" is "I am". With a voice, the word
    /// guard compares texts this way, so "do not" may become "don't" and back, and nothing else changes words.
    /// Only these; "John's" stays, and "it's" is always "it is", so "it has been" never becomes "it's been".
    public static func spellOut(_ s: String) -> String {
        let ns = s as NSString
        var out = "", last = 0
        for m in SmartCleanup.word.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let full = spelledOut(ns.substring(with: m.range)) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + full
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    static let irregular = ["can't": "can not", "cannot": "can not", "won't": "will not", "shan't": "shall not", "let's": "let us"]
    // ponytail: "'d" is always "would" and "'s" always "is", so a model writing "We would left" for "We'd left" passes;
    // telling "had" and "has" apart needs grammar. Add it if a model is seen writing that.
    static let suffixes = [("n't", " not"), ("'re", " are"), ("'ve", " have"), ("'ll", " will"), ("'m", " am"), ("'d", " would")]
    static let isTakers: Set<String> = ["it", "that", "what", "where", "who", "how", "here", "there", "he", "she"]

    static func spelledOut(_ word: String) -> String? {
        let w = word.replacingOccurrences(of: "’", with: "'"), lower = w.lowercased()
        if let e = irregular[lower] { return w.first!.isUppercase ? e.prefix(1).uppercased() + e.dropFirst() : e }
        for (suffix, full) in suffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
            return w.dropLast(suffix.count) + full
        }
        if lower.hasSuffix("'s"), isTakers.contains(String(lower.dropLast(2))) { return w.dropLast(2) + " is" }
        return nil
    }

    // MARK: examples

    /// A sample as dictation would give it, for the model's examples: one line, contractions spelled out, no emoji,
    /// "!" as ".", each sentence and "I" capitalized, and a final "." when the sample ends in a word.
    public static func asDictated(_ sample: String) -> String {
        var s = spellOut(sample.filter { !$0.unicodeScalars.contains { $0.properties.isEmojiPresentation } })
        s = s.replacingOccurrences(of: #"(?<=\?)!+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "!+", with: ".", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let ns = NSMutableString(string: s)
        for m in sentenceStart.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            ns.replaceCharacters(in: m.range, with: ns.substring(with: m.range).uppercased())
        }
        s = ns as String
        if let c = s.last, c.isLetter || c.isNumber { s += "." }
        return s
    }

    /// The first letter of a sentence, and a lone "i".
    static let sentenceStart = try! NSRegularExpression(pattern: #"(?:^|(?<=[.?!] ))\p{Ll}|\bi\b"#)
}
