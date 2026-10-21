import Foundation

/// F100: every hint, error and tip shown next to 🤫, kept so one the user missed can be read later on the Hub's
/// Home tab. In memory only: the last `cap`, newest first. The same text shown again right away is kept once, at
/// its latest time. Notices carry no dictated text: the hints never include it.
public struct NoticeLog {
    public struct Notice: Equatable {
        public let text: String
        public let time: Date
    }

    public static let cap = 50
    public private(set) var newestFirst: [Notice] = []

    public init() {}

    public mutating func append(_ text: String, at time: Date = Date()) {
        if newestFirst.first?.text == text { newestFirst.removeFirst() }
        newestFirst.insert(Notice(text: text, time: time), at: 0)
        if newestFirst.count > Self.cap { newestFirst.removeLast() }
    }

    /// "21.10.26 14:03" (dates as DD.MM.YY), the same on every locale.
    public static func time(_ d: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "dd.MM.yy HH:mm"
        return f.string(from: d)
    }
}
