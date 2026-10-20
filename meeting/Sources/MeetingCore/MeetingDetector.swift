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
    /// End evidence, e.g. the meeting window or tab is gone. Shortens the end wait.
    public var meetingWindowGone: Bool = false

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
    /// Seconds a meeting app must hold the mic before a meeting starts (grace).
    public var startAfter: Double = 5
    /// No starts this long after wake or a Core Audio restart.
    public var holdoff: Double = 10
    /// No end in the first seconds of a meeting.
    public var minSession: Double = 15
    /// Seconds after mic release before ending, with / without end evidence.
    public var endWithEvidence: Double = 3
    public var endWithoutEvidence: Double = 30
    /// The mic coming back within this window is the same meeting.
    public var reacquire: Double = 4
    /// An audio device change suppresses ends for this long.
    public var deviceChangeGrace: Double = 10
    /// Bundle ID prefixes that never count (shepetal's own dictation).
    public var selfBundleIDs: [String]

    private var pendingSince: [String: Double] = [:]
    private var lostSince: [String: Double] = [:]
    private var startedAt: [String: Double] = [:]
    private var holdoffUntil = -Double.infinity
    private var deviceGraceUntil = -Double.infinity
    public private(set) var active: Set<String> = []

    public init(selfBundleIDs: [String] = ["io.backant.shepetal", "shepetal"]) {
        self.selfBundleIDs = selfBundleIDs
    }

    /// Call after system wake or a coreaudiod restart.
    public mutating func wokeOrAudioRestarted(now: Double) { holdoffUntil = now + holdoff }
    /// Call when the default input/output device changes.
    public mutating func deviceChanged(now: Double) { deviceGraceUntil = now + deviceChangeGrace }

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
            } else if has(c.bundleID, prefix: "com.tinyspeck.slackmacgap") {
                // Slack holds the mic for clips too: only a visible huddle counts.
                let titles = s.windowTitles.filter { has($0.key, prefix: "com.tinyspeck.slackmacgap") }.values.joined()
                if titles.contains(where: { $0.lowercased().contains("huddle") }) { apps.insert("Slack") }
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
            if now - since >= startAfter && now >= holdoffUntil {
                pendingSince[app] = nil
                startedAt[app] = now
                active.insert(app)
                events.append(.started(app: app))
            }
        }
        // A candidate that drops out before startAfter starts over (flapping).
        for app in pendingSince.keys where !seen.contains(app) { pendingSince[app] = nil }
        for app in active.sorted() where !seen.contains(app) {
            let since = lostSince[app] ?? now
            lostSince[app] = since
            let wait = max(s.meetingWindowGone ? endWithEvidence : endWithoutEvidence, reacquire)
            if now - since >= wait && now - (startedAt[app] ?? now) >= minSession && now >= deviceGraceUntil {
                lostSince[app] = nil
                startedAt[app] = nil
                active.remove(app)
                events.append(.ended(app: app))
            }
        }
        return events
    }
}
