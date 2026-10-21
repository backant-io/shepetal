import Foundation

/// The personal dictionary: `dictionary.txt` in the data dir, one entry per line.
///   `GitHub`            a word or phrase: its casing is fixed in the text and it biases the model
///   `spoken => written` a replacement
///   `*` in front stars an entry (starred go first in the model hint); a line starting with `#` is a comment.
/// No entries ship by default. The file is re-read on every dictation, with snippets.toml (F40, `Snippets`).
public struct Vocabulary {
    public struct Entry: Equatable {
        public var spoken: String   // what to find, case-insensitive, whole words
        public var written: String  // what goes in its place
        public var starred: Bool
        public var isReplacement: Bool { spoken != written }

        public init(spoken: String, written: String, starred: Bool = false) {
            self.spoken = spoken; self.written = written; self.starred = starred
        }

        /// The entry as its dictionary.txt line.
        public var line: String { (starred ? "*" : "") + (isReplacement ? "\(spoken) => \(written)" : written) }
    }

    /// At most this many entries go to the model as a hint.
    public static let promptLimit = 200

    public static let header = """
        # Shepetal personal dictionary. One entry per line; changes apply on your next dictation.
        #   Kubernetes          a word or phrase, written with exactly this spelling and casing
        #   spoken => written   what you say on the left is replaced with the text on the right
        #   *Shepetal           a leading * stars an entry: starred entries go first in the hint to the model
        # Lines that start with # are comments.

        """

    public var entries: [Entry]
    public var snippets: [Snippet]

    public init(_ text: String = "", snippets: [Snippet] = []) {
        entries = text.split(whereSeparator: \.isNewline).compactMap(Self.entry)
        self.snippets = snippets
    }

    /// One line's entry; nil for a comment, a blank line or a half-written replacement.
    private static func entry(_ line: Substring) -> Entry? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
        let starred = s.hasPrefix("*")
        if starred { s = s.dropFirst().trimmingCharacters(in: .whitespaces) }
        var (spoken, written) = (s, s)
        if let arrow = s.range(of: "=>") {
            spoken = s[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            written = s[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        guard !spoken.isEmpty, !written.isEmpty else { return nil }
        return Entry(spoken: spoken, written: written, starred: starred)
    }

    /// The file's entries, and `snippets`' when given; a missing or unreadable file is empty. Keeps both owner-only.
    public static func load(_ url: URL, snippets: URL? = nil) -> Vocabulary {
        Vocabulary(readOwnerOnly(url) ?? "", snippets: snippets.map(Snippets.load) ?? [])
    }

    /// The file's text, nil when it is missing or unreadable. A file found is made 0600 again.
    static func readOwnerOnly(_ url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return String(decoding: data, as: UTF8.self)
    }

    /// Creates the file (0600) with the header comment if it is missing.
    public static func create(_ url: URL, header: String = header) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path),
           !fm.createFile(atPath: url.path, contents: Data(header.utf8), attributes: [.posixPermissions: 0o600]) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The hub's Dictionary tab (F91): `old`'s line becomes `new`'s, or goes when `new` is nil; with no `old`,
    /// `new` is added at the end. Comments, blank lines and every other line stay as they are. nil when `old`
    /// is no longer in `text` (the file was edited meanwhile), so nothing is written over that edit.
    public static func edit(_ text: String, replacing old: Entry?, with new: Entry?) -> String? {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if let old {
            guard let i = lines.firstIndex(where: { entry(Substring($0)) == old }) else { return nil }
            if let new { lines[i] = new.line } else { lines.remove(at: i) }
        } else if let new {
            if lines.last == "" { lines.removeLast() }
            lines += [new.line, ""]
        }
        return lines.joined(separator: "\n")
    }

    /// `edit` on the file, which is created with the header first if it is missing and stays owner-only.
    /// False, and the file untouched, when `old` is no longer in it.
    @discardableResult
    public static func update(_ url: URL, replacing old: Entry?, with new: Entry?) throws -> Bool {
        try create(url)
        guard let text = edit(String(decoding: try Data(contentsOf: url), as: UTF8.self), replacing: old, with: new)
        else { return false }
        try Data(text.utf8).write(to: url, options: .atomic)  // keeps the mode, which `create` just set to 0600
        return true
    }

    /// The snippet a dictation is when it is nothing but its trigger: case, punctuation, the non-speech tags and
    /// fillers ignored ("Um, my address." is "my address"). Checked on the words as heard, before any cleanup, so
    /// the cleanup model never rewrites a trigger.
    public func snippet(_ raw: String) -> Snippet? {
        let said = Snippets.normalize(Cleanup.apply(SpeechGuard.stripTags(raw)))
        guard !said.isEmpty else { return nil }
        return snippets.first { Snippets.normalize($0.trigger) == said }
    }

    /// Replaces every entry and snippet trigger in one pass: case-insensitive, whole words only, longest phrase
    /// first, so "new york city" wins over "new york" and a replacement is never replaced again. A snippet goes in
    /// as its plain text (rich text needs the whole dictation, `snippet`) and wins over an entry of the same length.
    public func apply(_ text: String) -> String {
        let rules = (snippets.map { ($0.trigger, $0.rendered.plain, false) } + entries.map { ($0.spoken, $0.written, $0.isReplacement) })
            .map { (key: $0.0.split(whereSeparator: \.isWhitespace).joined(separator: " "), written: $0.1, isReplacement: $0.2) }
            .filter { !$0.key.isEmpty }
        // Longest first; equal lengths keep their order, snippets first (Swift's sort is not documented as stable).
        let sorted = rules.enumerated().sorted { ($0.element.key.count, $1.offset) > ($1.element.key.count, $0.offset) }.map(\.element)
        guard !sorted.isEmpty else { return text }
        let alternatives = sorted.map { e in
            e.key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        }
        let pattern = #"(?<!\w)(?:"# + alternatives.joined(separator: "|") + #")(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let found = ns.substring(with: m.range)
            let squashed = found.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard let e = sorted.first(where: { $0.key.compare(squashed, options: .caseInsensitive) == .orderedSame })
            else { continue }
            var written = e.written
            // A replacement at the start of a sentence keeps its capital ("Btw" -> "By the way").
            if e.isReplacement, found.first?.isUppercase == true, written.first?.isLowercase == true {
                written = written.prefix(1).uppercased() + written.dropFirst()
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + written
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// The hint for the speech model: starred entries first, then file order, at most `promptLimit`.
    /// It holds the spoken side, which is what the model has to hear for a replacement to fire.
    public var promptTerms: [String] {
        let terms = entries.filter(\.starred) + entries.filter { !$0.starred }
        return Array(terms.map(\.spoken).prefix(Self.promptLimit))
    }
}
