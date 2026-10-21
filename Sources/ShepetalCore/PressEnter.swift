import Foundation

/// F42: a dictation that ends with "press enter" is pasted without the phrase, then Return is pressed, but only
/// after the paste landed in the window that kept focus (rule 8). Off until the user turns it on in Settings,
/// as Wispr ships it (docs/re/insertion-context.md).
public enum PressEnter {
    /// The Settings toggle (UserDefaults, Bool, off by default).
    public static let key = "pressEnterCommand"
    /// A dictation of only "press enter": nothing is pasted and Return is not pressed, since no paste confirms
    /// that the window takes text.
    public static let nothingToSend = "Say the text first, then “press enter”."

    private static let trailing = try! NSRegularExpression(pattern: #"(?i)\bpress\s+enter\b([\s.!?]*)$"#)

    /// The text without a trailing "press enter", and whether Return should follow the paste. The phrase counts
    /// at the end of `text`, or at the end of `raw` when cleanup dropped it from `text` (as Wispr does,
    /// docs/re/text-pipeline.md). A "press enter" in the middle of a sentence is text.
    public static func split(_ text: String, raw: String) -> (text: String, enter: Bool) {
        guard let rest = strip(text) else { return (text, strip(raw) != nil) }
        return (rest, true)
    }

    /// "See you soon, press enter." gives "See you soon.": the commas and spaces before the phrase go, and its
    /// sentence end moves to the text before it. nil when the text does not end with the phrase.
    static func strip(_ s: String) -> String? {
        let ns = s as NSString
        guard let m = trailing.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var rest = ns.substring(to: m.range.location)
        while let last = rest.last, last.isWhitespace || ",;:-".contains(last) { rest.removeLast() }
        let end = ns.substring(with: m.range(at: 1)).first { ".!?".contains($0) }
        if let end, let last = rest.last, !".!?".contains(last) { rest.append(end) }
        return rest
    }
}
