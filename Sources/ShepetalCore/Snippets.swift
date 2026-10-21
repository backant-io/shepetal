import Foundation

/// A snippet (F40): saying `trigger` inserts `expansion`. Said alone, the dictation becomes the expansion, exactly as
/// stored; said inside a sentence, the trigger is replaced there, in the dictionary's pass (`Vocabulary.apply`).
public struct Snippet: Equatable, Sendable {
    public var trigger: String
    /// As stored. Markdown inline markup in it (bold, italic, code, strikethrough, links) is pasted as rich text.
    public var expansion: String

    public init(trigger: String, expansion: String) {
        self.trigger = trigger; self.expansion = expansion
    }

    /// `plain` is what a plain-text field gets: the expansion with its markup rendered away, or exactly as stored
    /// when it has none. `html` is the same text for fields that take rich text; nil without markup.
    public var rendered: (plain: String, html: String?) { Snippets.render(expansion) }
}

/// snippets.toml in the data dir, in Linux's format (docs/linux-vocab.md): one `"trigger" = "expansion"` pair per
/// line, both TOML basic strings, so `\n` is a new line. Owner-only, re-read on every dictation. No snippet ships.
public enum Snippets {
    public static let header = #"""
        # shepetal snippets. One per line: "what you say" = "the text it becomes". Changes apply on your next dictation.
        #   "my address" = "221B Baker Street\nLondon"                    \n starts a new line
        #   "my signature" = "**Ada Lovelace**\n[backant.io](https://backant.io)"   **bold**, *italic* and [links](…) paste as rich text
        # Say just the trigger and the text goes in exactly as written. Inside a sentence, the trigger is replaced there.
        # Lines that start with # are comments.

        """#

    /// The pairs in file order. A line that is not one whole pair (a comment, a half-written pair, an unknown
    /// escape) is skipped, as is a blank trigger.
    public static func parse(_ text: String) -> [Snippet] {
        text.split(whereSeparator: \.isNewline).compactMap(pair)
    }

    /// The file's snippets; a missing or unreadable file has none. Keeps the file owner-only.
    public static func load(_ url: URL) -> [Snippet] {
        Vocabulary.readOwnerOnly(url).map(parse) ?? []
    }

    /// Creates the file (0600) with the header comment if it is missing.
    public static func create(_ url: URL) throws { try Vocabulary.create(url, header: header) }

    private static func pair(_ line: Substring) -> Snippet? {
        var s = line.unicodeScalars[...]
        func skipSpaces() { while s.first == " " || s.first == "\t" { s.removeFirst() } }
        func take(_ c: Unicode.Scalar) -> Bool {
            guard s.first == c else { return false }
            s.removeFirst()
            return true
        }
        skipSpaces()
        guard take("\""), let trigger = basicString(&s) else { return nil }
        skipSpaces()
        guard take("=") else { return nil }
        skipSpaces()
        guard take("\""), let expansion = basicString(&s) else { return nil }
        skipSpaces()
        guard s.isEmpty || s.first == "#", !trigger.allSatisfy(\.isWhitespace) else { return nil }
        return Snippet(trigger: trigger, expansion: expansion)
    }

    /// A TOML basic string's body up to its closing quote, which is consumed. nil for a bad escape, a control
    /// character or a missing quote, as on Linux.
    private static func basicString(_ s: inout Substring.UnicodeScalarView) -> String? {
        var out = String.UnicodeScalarView()
        while let c = s.popFirst() {
            switch c {
            case "\"": return String(out)
            case "\\":
                switch s.popFirst() {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u":
                    let hex = String(String.UnicodeScalarView(s.prefix(4)))
                    guard hex.unicodeScalars.count == 4, let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else { return nil }
                    s.removeFirst(4)
                    out.append(u)
                default: return nil
                }
            case _ where c.value < 0x20: return nil
            default: out.append(c)
            }
        }
        return nil
    }

    /// Lowercase words with punctuation dropped: "My address." and "my  address" are the same.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    /// Markdown inline markup, newlines kept, to the plain text and an HTML fragment. Text with no markup is left
    /// exactly as it is, html nil. The HTML names no font, so the field's own font is used where the app allows it.
    public static func render(_ markdown: String) -> (plain: String, html: String?) {
        guard let a = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
              a.runs.contains(where: { $0.inlinePresentationIntent != nil || $0.link != nil }) else { return (markdown, nil) }
        var html = #"<meta charset="utf-8">"#  // without it, an app may read the bytes as Latin-1
        for run in a.runs {
            var s = escape(String(a[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>")
            let intent = run.inlinePresentationIntent ?? []
            for (flag, tag) in [(InlinePresentationIntent.code, "code"), (.strikethrough, "s"), (.emphasized, "i"),
                                (.stronglyEmphasized, "b")] where intent.contains(flag) {
                s = "<\(tag)>\(s)</\(tag)>"
            }
            if let url = run.link { s = #"<a href="\#(escape(url.absoluteString))">\#(s)</a>"# }
            html += s
        }
        return (String(a.characters), html)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
