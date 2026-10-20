/// A process that is currently capturing audio input.
public struct MicClient: Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// One observation of the system, taken about once a second.
public struct Snapshot: Sendable {
    public var micClients: [MicClient]
    /// Window titles keyed by the owning app's bundle ID (browsers matter).
    public var windowTitles: [String: [String]]
    /// Title of the calendar event happening now, if any.
    public var calendarEvent: String?

    public init(micClients: [MicClient] = [],
                windowTitles: [String: [String]] = [:], calendarEvent: String? = nil) {
        self.micClients = micClients
        self.windowTitles = windowTitles
        self.calendarEvent = calendarEvent
    }
}

public enum MeetingEvent: Equatable, Sendable {
    case started(app: String)
    case ended(app: String)
}

public enum KnownApps {
    /// Native apps that only hold the mic during a call. Matched by case-insensitive bundle ID
    /// prefix, so helpers (`us.zoom.xos.helper`, `com.microsoft.teams2.modulehost`) count too.
    public static let native: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),  // also matches com.microsoft.teams2
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.webex.meetingmanager", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.hnc.Discord", "Discord"),
    ]

    /// Browsers. Their mic is held by a helper whose bundle ID starts with these.
    public static let browsers: [(prefix: String, name: String)] = [
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),  // Safari's audio runs in the WebKit GPU process
        ("company.thebrowser.Browser", "Arc"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("com.operasoftware.Opera", "Opera"),
        ("org.chromium.Chromium", "Chromium"),
    ]

    /// Web meetings recognised by the browser window (tab) title.
    public static let webTitles: [(needle: String, name: String)] = [
        ("Meet - ", "Google Meet"),
        ("Meet – ", "Google Meet"),
        ("Google Meet", "Google Meet"),
        ("meet.google.com", "Google Meet"),
        ("Microsoft Teams", "Microsoft Teams"),
        ("Zoom Meeting", "Zoom"),
        ("app.zoom.us", "Zoom"),
    ]
}

/// Turns snapshots into debounced meetingStarted / meetingEnded events.
/// Pure state machine: the caller supplies the clock, so it is fully testable.
public struct MeetingDetector: Sendable {
    /// Seconds a meeting app must hold the mic before a meeting starts.
    public var startAfter: Double
    /// Seconds the mic must be released before the meeting ends.
    public var endAfter: Double
    /// Bundle ID prefixes that never count (shepetal's own dictation).
    public var selfBundleIDs: [String]

    private var pendingSince: [String: Double] = [:]
    private var lostSince: [String: Double] = [:]
    public private(set) var active: Set<String> = []

    public init(startAfter: Double = 5, endAfter: Double = 10,
                selfBundleIDs: [String] = ["io.backant.shepetal", "shepetal"]) {
        self.startAfter = startAfter
        self.endAfter = endAfter
        self.selfBundleIDs = selfBundleIDs
    }

    func isSelf(_ c: MicClient) -> Bool {
        c.name.lowercased().contains("shepetal")
            || selfBundleIDs.contains { has(c.bundleID, prefix: $0) }
    }

    func has(_ id: String, prefix: String) -> Bool { id.lowercased().hasPrefix(prefix.lowercased()) }

    /// The meeting apps visible in one snapshot, ignoring debounce.
    public func meetingApps(in s: Snapshot) -> Set<String> {
        var apps: Set<String> = []
        for c in s.micClients where !isSelf(c) {
            if let n = KnownApps.native.first(where: { has(c.bundleID, prefix: $0.prefix) }) {
                apps.insert(n.name)
            } else if let b = KnownApps.browsers.first(where: { has(c.bundleID, prefix: $0.prefix) }) {
                // The mic helper and the window owner can differ (WebKit.GPU vs Safari): match by browser.
                let prefixes = KnownApps.browsers.filter { $0.name == b.name }.map(\.prefix)
                let titles = s.windowTitles.filter { k, _ in prefixes.contains { has(k, prefix: $0) } }.values.joined()
                if let w = KnownApps.webTitles.first(where: { t in titles.contains { $0.contains(t.needle) } }) {
                    apps.insert("\(w.name) (\(b.name))")
                }
            } else if let event = s.calendarEvent {
                // Unknown app holding the mic during a calendar event: likely a meeting.
                apps.insert("\(c.name): \(event)")
            }
        }
        return apps
    }

    public mutating func update(_ s: Snapshot, now: Double) -> [MeetingEvent] {
        let seen = meetingApps(in: s)
        var events: [MeetingEvent] = []
        for app in seen.sorted() {
            lostSince[app] = nil
            if active.contains(app) { continue }
            let since = pendingSince[app] ?? now
            pendingSince[app] = since
            if now - since >= startAfter {
                pendingSince[app] = nil
                active.insert(app)
                events.append(.started(app: app))
            }
        }
        // A candidate that drops out before startAfter starts over (flapping).
        for app in pendingSince.keys where !seen.contains(app) { pendingSince[app] = nil }
        for app in active.sorted() where !seen.contains(app) {
            let since = lostSince[app] ?? now
            lostSince[app] = since
            if now - since >= endAfter {
                lostSince[app] = nil
                active.remove(app)
                events.append(.ended(app: app))
            }
        }
        return events
    }
}
