import Foundation

/// F28: the last links the user copied, kept in memory only (never written to disk), newest first, each for
/// 24 hours. A link copied again moves to the front.
public struct LinkMemory {
    public static let capacity = 20
    public static let lifetime: TimeInterval = 24 * 3600
    private var items: [(url: String, at: Date)] = []

    public init() {}

    public mutating func add(_ url: String, at now: Date = Date()) {
        items.removeAll { $0.url == url || now.timeIntervalSince($0.at) >= Self.lifetime }
        items.insert((url, now), at: 0)
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
    }

    /// Newest first, the expired ones left out.
    public func links(now: Date = Date()) -> [String] {
        items.filter { now.timeIntervalSince($0.at) < Self.lifetime }.map(\.url)
    }
}

public enum Links {
    /// The markers that say "do not keep this": password managers set Concealed, and Shepetal's own pastes set both.
    public static let skipTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    public static func skips(types: [String]) -> Bool { types.contains(where: skipTypes.contains) }

    /// The copied string when it is one whole http(s) URL with a host, else nil. A URL with a user or password in
    /// it is not kept, nor is text around a URL.
    public static func url(from copied: String) -> String? {
        let s = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace), let c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        return s
    }

    /// "insert link" and "insert the last link" (the newest), "insert link two" or "insert link number 2" (the one
    /// before it), up to twenty. Only these commands: without a model, "send me that link" is ordinary speech.
    static let command = try! NSRegularExpression(pattern: #"(?i)\binsert\s+(?:(?:the\s+)?last\s+link|link(?:\s+(?:number\s+)?(?<n>\d{1,2}|"#
        + numberWords.joined(separator: "|") + #"))?)\b(?:\.\s*$)?"#)
    static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                              "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                              "nineteen", "twenty"]

    /// Each command becomes its link (`links` newest first). A command whose link is not there stays as said. A
    /// period right after a command that ends the text goes, so the link is pasted bare.
    public static func insert(_ text: String, links: [String]) -> String {
        guard !links.isEmpty else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for m in command.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let n = m.range(withName: "n")
            let number = n.location == NSNotFound ? "1" : ns.substring(with: n).lowercased()
            guard let i = Int(number) ?? numberWords.firstIndex(of: number).map({ $0 + 1 }), (1...links.count).contains(i) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + links[i - 1]
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
