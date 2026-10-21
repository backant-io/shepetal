import Foundation

/// F37: the kind of app a dictation goes to, from its bundle id or, in a browser, the page's host.
public enum AppCategory: String, CaseIterable, Sendable {
    case work, personal, email, other
}

/// F37: how a dictation is written for one kind of app. Rules only, no model (Pavel, 21.10.26).
/// Formal is the text as dictation wrote it before styles existed, and the default everywhere.
public enum Style: String, CaseIterable, Sendable {
    case formal, casual, veryCasual, excited
}

public enum Styles {
    /// Lowercased bundle ids. Work messages: Slack and Teams. Email: Mail, Outlook, Superhuman, Spark, Mimestream,
    /// Thunderbird and Airmail.
    /// Personal messages: Messages, WhatsApp, Telegram, Signal, WeChat and Messenger.
    static let apps: [String: AppCategory] = [
        "com.tinyspeck.slackmacgap": .work, "com.microsoft.teams2": .work, "com.microsoft.teams": .work,
        "com.apple.mail": .email, "com.microsoft.outlook": .email, "com.superhuman.electron": .email,
        "com.readdle.smartemail-mac": .email, "com.readdle.sparkdesktop": .email, "com.mimestream.mimestream": .email,
        "org.mozilla.thunderbird": .email, "it.bloop.airmail2": .email,
        "com.apple.mobilesms": .personal, "net.whatsapp.whatsapp": .personal, "desktop.whatsapp": .personal,
        "ru.keepcoder.telegram": .personal, "com.tdesktop.telegram": .personal,
        "org.whispersystems.signal-desktop": .personal, "com.tencent.xinwechat": .personal,
        "com.facebook.archon": .personal, "com.facebook.archon.developerid": .personal,
    ]

    /// The same apps on the web. A host matches itself and its subdomains (any workspace.slack.com).
    static let hosts: [String: AppCategory] = [
        "slack.com": .work, "teams.microsoft.com": .work, "teams.live.com": .work, "teams.cloud.microsoft": .work,
        "mail.google.com": .email, "outlook.live.com": .email, "outlook.office.com": .email,
        "outlook.office365.com": .email, "outlook.cloud.microsoft": .email, "mail.superhuman.com": .email,
        "mail.proton.me": .email, "app.fastmail.com": .email,
        "web.whatsapp.com": .personal, "web.telegram.org": .personal, "messenger.com": .personal,
    ]

    /// `url` is the history row's URL (set for browsers only). Anything not listed is Other.
    public static func category(bundleId: String, url: String) -> AppCategory {
        if let c = apps[bundleId.lowercased()] { return c }
        guard var host = URL(string: url)?.host?.lowercased() else { return .other }
        while true {
            if let c = hosts[host] { return c }
            guard let dot = host.firstIndex(of: ".") else { return .other }
            host = String(host[host.index(after: dot)...])
        }
    }

    public static func key(_ category: AppCategory) -> String { "style." + category.rawValue }

    /// The style picked in Settings for this app's category. Formal when none was picked or the value is unknown.
    public static func chosen(bundleId: String, url: String, _ defaults: UserDefaults = .standard) -> Style {
        defaults.string(forKey: key(category(bundleId: bundleId, url: url))).flatMap(Style.init(rawValue:)) ?? .formal
    }

    /// Runs after the dates and before the personal dictionary, so dictionary words keep their casing.
    /// Questions keep "?", and URLs, decimals, abbreviations and "DD.MM." dates are left as they are.
    public static func apply(_ style: Style, to text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch style {
        case .formal: return text
        case .casual: return dropFinalPeriod(fewerCommas(t))
        case .veryCasual: return dropFinalPeriod(lowercased(fewerCommas(t)))
        case .excited: return exclaim(t)
        }
    }

    /// A URL, web address or email address: its case and dots are never changed.
    static let url = try! NSRegularExpression(pattern: #"""
        (?xi) [a-z][a-z0-9+.-]*://\S+ | www\.\S+ | [^\s@]+@[^\s@]+\.[a-z]{2,}
        | [a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}(?:/\S*)?
        """#)
    /// A greeting or interjection opening a sentence, and the comma after it (with a name after a greeting:
    /// "Hey Anna,"). ponytail: these words only; other commas stay.
    static let opener = try! NSRegularExpression(pattern: #"""
        (^|[.!?…]\s+|\n\s*)
        ( (?i:hi|hey|hello|hallo|dear)(?:\s+\p{Lu}\p{Ll}[\p{L}'’-]*)?
        | (?i:oh|ah|ok|okay|yeah|yes|yep|no|nope|well|so|sure|thanks|wow|alright|ja|nein|naja|also|danke|genau|ach) )
        ,(?=\s)
        """#, options: [.allowCommentsAndWhitespace])
    /// A final dot that is not the sentence's: "p.m.", "z.B.", "etc.", "usw." and a "DD.MM." date.
    static let ownDot = try! NSRegularExpression(pattern: #"""
        (?: (?<!\p{L})(?:\p{L}\.){2,} | (?<!\p{L})(?i:etc|vs|inc|ltd|jr|sr|usw|bzw|ca)\.
        | (?<![\w.])(?:0[1-9]|[12][0-9]|3[01])\.(?:0[1-9]|1[0-2])\. ) $
        """#, options: [.allowCommentsAndWhitespace])

    static func fewerCommas(_ s: String) -> String {
        opener.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2")
    }

    /// Everything lowercase, "I" too, except URLs.
    static func lowercased(_ s: String) -> String {
        var out = "", last = s.startIndex
        for m in url.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out += s[last..<r.lowerBound].lowercased() + s[r]
            last = r.upperBound
        }
        return out + s[last...].lowercased()
    }

    static func dropFinalPeriod(_ s: String) -> String {
        guard s.hasSuffix("."), !s.hasSuffix(".."), !matches(ownDot, s) else { return s }
        return String(s.dropLast())
    }

    /// The last sentence ends in "!". One ending in "?", "!", "…" or another mark, or in a URL, is left alone.
    static func exclaim(_ s: String) -> String {
        guard !s.hasSuffix(".."), let last = s.last, last.isLetter || last.isNumber || last == "." else { return s }
        let body = last == "." && !matches(ownDot, s) ? String(s.dropLast()) : s
        if let m = url.matches(in: body, range: NSRange(body.startIndex..., in: body)).last,
           m.range.location + m.range.length == (body as NSString).length { return s }
        return body + "!"
    }

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
