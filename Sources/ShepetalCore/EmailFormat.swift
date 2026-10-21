import Foundation

/// F36: a dictation into an email app is laid out like an email, by rules (no model). A leading greeting goes on
/// its own line with a blank line after it, and a trailing sign-off goes into its own paragraph with the name on
/// the line below. When no name was said, the user's own signature (Settings, empty by default) stands in for it.
/// The body is not split into paragraphs. Email apps are Styles' Email category (F37), so both read one table.
public enum EmailFormat {
    /// Settings' signature (UserDefaults, String). Empty adds nothing.
    public static let signatureKey = "emailSignature"

    public static func isEmail(bundleId: String, url: String) -> Bool {
        Styles.category(bundleId: bundleId, url: url) == .email
    }

    /// "Hi Anna," "Hello team," "Sehr geehrte Frau Dr. Müller,": a greeting word, up to four names, titles or
    /// group words, then a comma, period or "!". A period becomes a comma. "Hey can you…" has no greeting line.
    static let greeting = try! NSRegularExpression(pattern: #"""
        (?x) ^ (?<g> (?<w> (?i: hi | hello | hey | dear | good \s+ (?:morning|afternoon|evening)
                          | hallo | liebe[rs]? | sehr \s+ geehrte[rs]? | guten \s+ (?:morgen|tag|abend) | moin | servus ) )
        (?: ,? \s+ (?: (?:Mr|Mrs|Ms|Dr|Prof)\. | (?!(?:Mr|Mrs|Ms|Dr|Prof)\.) \p{Lu}[\p{L}'’-]*
                     | (?i: team | all | everyone | everybody | there | folks | zusammen | alle | and | und | or ) \b ) ){0,4}? )
        \s* (?<t> [,.!] ) (?: \s+ | $ )
        """#)
    /// "Thanks," "Best regards, Pavel" "Viele Grüße Anna Schmidt": a sign-off opening the last sentence, then
    /// up to three capitalized words for the name, and nothing after it.
    static let signOff = try! NSRegularExpression(pattern: #"""
        (?x) (?: ^ | (?<=[.!?…]) \s+ | \n\s* )
        (?<p> (?i: thanks | thank \s+ you | many \s+ thanks | best (?:\s+ regards)? | kind \s+ regards | warm \s+ regards
                 | regards | cheers | sincerely | all \s+ the \s+ best
                 | (?<de> viele \s+ grüße | liebe \s+ grüße | beste \s+ grüße | herzliche \s+ grüße | schöne \s+ grüße
                        | mit \s+ freundlichen \s+ grüßen ) ) )
        \s* (?<t> [,.!] )?
        (?: \s+ (?<n> \p{Lu}[\p{L}'’-]* (?: \s+ \p{Lu}[\p{L}'’-]* ){0,2} ) \s* [.!]? )?
        \s* $
        """#)

    /// The text laid out, or as it was when it has neither a greeting with more after it nor a sign-off.
    public static func apply(_ text: String, signature: String = "") -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var head: String?, tail: String?
        if let m = first(signOff, body) {
            let german = m.range(withName: "de").location != NSNotFound
            let mark = group(m, "t", body) == "!" ? "!" : german ? "" : ","
            let name = group(m, "n", body) ?? signature.trimmingCharacters(in: .whitespacesAndNewlines)
            tail = group(m, "p", body)! + mark + (name.isEmpty ? "" : "\n" + name)
            body = String(body[..<Range(m.range, in: body)!.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let m = first(greeting, body) {
            let rest = String(body[Range(m.range, in: body)!.upperBound...])
            if !rest.isEmpty || tail != nil {
                head = group(m, "g", body)! + (group(m, "t", body) == "!" ? "!" : ",")
                // English goes on with a capital; German goes on in lowercase after "Liebe Anna,".
                body = english(group(m, "w", body)!) ? capitalized(rest) : rest
            }
        }
        guard head != nil || tail != nil else { return text }
        return [head, body, tail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func english(_ word: String) -> Bool {
        ["hi", "hello", "hey", "dear"].contains(word.lowercased()) || word.lowercased().hasPrefix("good")
    }

    /// "thanks for the file" → "Thanks for the file". A first word with a capital, digit or mark in it ("iPhone",
    /// "https://…", "e.g.") stays as it is.
    private static func capitalized(_ s: String) -> String {
        let word = s.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:"))
        guard let f = word.first, word.allSatisfy({ $0.isLowercase || $0 == "'" || $0 == "’" }) else { return s }
        return f.uppercased() + s.dropFirst()
    }

    private static func first(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func group(_ m: NSTextCheckingResult, _ name: String, _ s: String) -> String? {
        Range(m.range(withName: name), in: s).map { String(s[$0]) }
    }
}
