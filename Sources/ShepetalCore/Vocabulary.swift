import Foundation

/// The personal dictionary: `dictionary.txt` in the data dir, one entry per line.
///   `GitHub`            a word or phrase: its casing is fixed in the text and it biases the model
///   `spoken => written` a replacement
///   `*` in front stars an entry (starred go first in the model hint); a line starting with `#` is a comment.
/// No entries ship by default. The file is re-read on every dictation.
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

    public init(_ text: String = "") {
        entries = text.split(whereSeparator: \.isNewline).compactMap(Self.entry)
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

    /// The file's entries; a missing or unreadable file is an empty dictionary. Keeps the file owner-only.
    public static func load(_ url: URL) -> Vocabulary {
        guard let data = FileManager.default.contents(atPath: url.path) else { return Vocabulary() }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return Vocabulary(String(decoding: data, as: UTF8.self))
    }

    /// Creates the file (0600) with the header comment if it is missing.
    public static func create(_ url: URL) throws {
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

    /// Replaces every entry in one pass: case-insensitive, whole words only, longest phrase first,
    /// so "new york city" wins over "new york" and a replacement is never replaced again.
    public func apply(_ text: String) -> String {
        let sorted = entries.sorted { $0.spoken.count > $1.spoken.count }
        guard !sorted.isEmpty else { return text }
        let alternatives = sorted.map { e in
            e.spoken.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        }
        let pattern = #"(?<!\w)(?:"# + alternatives.joined(separator: "|") + #")(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let found = ns.substring(with: m.range)
            let squashed = found.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard let e = sorted.first(where: { $0.spoken.compare(squashed, options: .caseInsensitive) == .orderedSame })
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
