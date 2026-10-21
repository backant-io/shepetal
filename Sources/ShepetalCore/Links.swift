import Foundation

/// F28: the last links the user copied, kept in memory only (never written to disk), newest first, each for
/// 24 hours. A link copied again moves to the front.
public struct LinkMemory {
    public static let capacity = 20
    public static let lifetime: TimeInterval = 24 * 3600
    /// `url` is nil for a link that is never offered; `key` knows a copy again without keeping it.
    private var items: [(url: String?, key: Int, at: Date)] = []

    public init() {}

    /// A copy. A link to offer goes to the front. A link that is never offered (Links.url turns it down: a secret
    /// or a password in it) still takes the front, as a blank, so "insert link" then stays as words instead of
    /// pasting a link copied before it. Only its hash is kept. A copy that is not one whole link changes nothing.
    public mutating func add(_ copied: String, at now: Date = Date()) {
        let s = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Links.isLink(s) else { return }
        let key = s.hashValue
        items.removeAll { $0.key == key || now.timeIntervalSince($0.at) >= Self.lifetime }
        items.insert((Links.url(from: s), key, now), at: 0)
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
    }

    /// Newest first, the expired ones left out; nil where a link is never offered.
    public func links(now: Date = Date()) -> [String?] {
        items.filter { now.timeIntervalSince($0.at) < Self.lifetime }.map(\.url)
    }
}

public enum Links {
    /// The markers that say "do not keep this": password managers set Concealed, and Shepetal's own pastes set both.
    public static let skipTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    public static func skips(types: [String]) -> Bool { types.contains(where: skipTypes.contains) }

    /// The copied string when it is one whole http(s) URL with a host, else nil. A URL with a user or password in
    /// it is not kept, nor one with a secret in its query or fragment, nor text around a URL.
    public static func url(from copied: String) -> String? {
        let s = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = components(s), c.user == nil, c.password == nil, !carriesSecret(c) else { return nil }
        return s
    }

    /// One whole http(s) URL with a host, kept or not: no text around it, no other scheme.
    public static func isLink(_ copied: String) -> Bool {
        components(copied.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private static func components(_ s: String) -> URLComponents? {
        guard !s.isEmpty, !s.contains(where: \.isWhitespace), let c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        return c
    }

    /// Parameter names that carry a sign-in, reset or signed-URL secret. Any name containing one counts, so
    /// "access_token", "apiKey", "X-Amz-Signature" and "sessionid" do too. ponytail: a name like "keyword" is
    /// skipped as well, and a secret in the path itself is not seen; a link not kept is only a link not offered.
    static let secretNames = ["token", "key", "sig", "code", "auth", "session", "pass", "pwd", "secret", "credential",
                              "jwt", "otp", "ticket"]

    /// The query's names, and the fragment's (OAuth puts "#access_token=" there). A plain anchor like "#keys" is
    /// not a parameter.
    static func carriesSecret(_ c: URLComponents) -> Bool {
        let fragment = (c.fragment ?? "").split(separator: "&").filter { $0.contains("=") }.map { String($0.prefix { $0 != "=" }) }
        return ((c.queryItems ?? []).map(\.name) + fragment).contains { name in secretNames.contains(where: name.lowercased().contains) }
    }

    /// "insert link" and "insert the last link" (the newest), "insert link two" or "insert link number 2" (the one
    /// before it), up to twenty. Only these commands: without a model, "send me that link" is ordinary speech.
    static let command = try! NSRegularExpression(pattern: #"(?i)\binsert\s+(?:(?:the\s+)?last\s+link|link(?:\s+(?:number\s+)?(?<n>\d{1,2}|"#
        + numberWords.joined(separator: "|") + #"))?)\b(?:\.\s*$)?"#)
    static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                              "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                              "nineteen", "twenty"]

    /// Each command in `text` becomes its link (`links` newest first), but only a command the user said: `said`, the
    /// transcript before any model, must hold the same command (same link) once for each one expanded. So words the
    /// cleanup model wrote, from the field around the cursor (F24) or its own, never paste a link. A command whose
    /// link is not there, or is never offered (nil), stays as said. A period right after a command that ends the
    /// text goes, so the link is pasted bare.
    public static func insert(_ text: String, links: [String?], said: String) -> String {
        var spoken = commands(in: said).map(\.link)
        let ns = text as NSString
        var out = "", last = 0
        for (range, link) in commands(in: text) {
            guard links.indices.contains(link - 1), let url = links[link - 1], let k = spoken.firstIndex(of: link) else { continue }
            spoken.remove(at: k)
            out += ns.substring(with: NSRange(location: last, length: range.location - last)) + url
            last = range.location + range.length
        }
        return out + ns.substring(from: last)
    }

    /// Where each command is in `text` and the link it names, 1 the newest.
    static func commands(in text: String) -> [(range: NSRange, link: Int)] {
        let ns = text as NSString
        return command.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let n = m.range(withName: "n")
            let number = n.location == NSNotFound ? "1" : ns.substring(with: n).lowercased()
            return (m.range, Int(number) ?? (numberWords.firstIndex(of: number) ?? -1) + 1)
        }
    }
}
