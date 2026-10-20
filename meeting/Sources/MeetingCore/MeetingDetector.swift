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
    /// Default input and output devices. A change starts the device-change grace.
    public var devices: [UInt32]
    /// Changes on system wake or an audio server restart (Mac: kern.waketime + coreaudiod
    /// restart count). A change starts the holdoff.
    public var wakeMarker: String

    public init(micClients: [MicClient] = [], windowTitles: [String: [String]] = [:],
                calendarEvent: String? = nil, devices: [UInt32] = [], wakeMarker: String = "") {
        self.micClients = micClients
        self.windowTitles = windowTitles
        self.calendarEvent = calendarEvent
        self.devices = devices
        self.wakeMarker = wakeMarker
    }
}

public struct CalendarEvent: Sendable {
    public var title: String
    public var start: Double
    public var end: Double
    public var isAllDay: Bool
    public init(title: String, start: Double, end: Double, isAllDay: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }

    /// The event mic use is tied to: not all-day, within `proximity` seconds of its time span
    /// (docs/re/meetings.md: events within 5 min correlate), nearest start first.
    public static func current(in events: [CalendarEvent], now: Double, proximity: Double = 300) -> String? {
        events.filter { !$0.isAllDay && $0.start - proximity <= now && now <= $0.end + proximity }
            .min { abs($0.start - now) < abs($1.start - now) }?.title
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
    /// Seconds after mic release before ending. Bound: a native app let go of the mic, or the
    /// tab/window/event that proved the meeting is gone too. Unbound: that proof is still there.
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
    /// Mic holders seen for each active meeting.
    private var holders: [String: Set<MicClient>] = [:]
    private var holdoffUntil = -Double.infinity
    private var deviceGraceUntil = -Double.infinity
    private var lastDevices: [UInt32]?
    private var lastWakeMarker: String?
    public private(set) var active: Set<String> = []

    public init(selfBundleIDs: [String] = ["io.backant.shepetal", "shepetal"]) {
        self.selfBundleIDs = selfBundleIDs
    }

    /// Call after system wake or a coreaudiod restart (`update` does this when `wakeMarker` changes).
    public mutating func wokeOrAudioRestarted(now: Double) { holdoffUntil = now + holdoff }
    /// Call when the default input/output device changes (`update` does this when `devices` change).
    public mutating func deviceChanged(now: Double) { deviceGraceUntil = now + deviceChangeGrace }

    func isSelf(_ c: MicClient) -> Bool {
        c.name.lowercased().contains("shepetal")
            || selfBundleIDs.contains { has(c.bundleID, prefix: $0) }
    }

    func has(_ id: String, prefix: String) -> Bool { id.lowercased().hasPrefix(prefix.lowercased()) }

    /// The meeting apps visible in one snapshot, ignoring debounce.
    public func meetingApps(in s: Snapshot) -> Set<String> { Set(matches(in: s).keys) }

    /// Meeting apps in one snapshot with the mic clients that make each one.
    func matches(in s: Snapshot) -> [String: Set<MicClient>] {
        var apps: [String: Set<MicClient>] = [:]
        for c in s.micClients where !isSelf(c) {
            var app: String?
            if let n = KnownApps.native.first(where: { has(c.bundleID, prefix: $0.prefix) }) {
                app = n.name
            } else if has(c.bundleID, prefix: "com.tinyspeck.slackmacgap") {
                // Slack holds the mic for clips too: only a visible huddle counts.
                let titles = s.windowTitles.filter { has($0.key, prefix: "com.tinyspeck.slackmacgap") }.values.joined()
                if titles.contains(where: { $0.lowercased().contains("huddle") }) { app = "Slack" }
            } else if let b = KnownApps.browsers.first(where: { has(c.bundleID, prefix: $0.prefix) }) {
                // The mic helper and the window owner can differ (WebKit.GPU vs Safari): match by browser.
                let prefixes = KnownApps.browsers.filter { $0.name == b.name }.map(\.prefix)
                let titles = s.windowTitles.filter { k, _ in prefixes.contains { has(k, prefix: $0) } }.values.joined()
                if let w = KnownApps.webTitles.first(where: { t in titles.contains { $0.contains(t.needle) } }) {
                    app = "\(w.name) (\(b.name))"
                }
            } else if let event = s.calendarEvent {
                // Unknown app holding the mic during a calendar event: likely a meeting.
                app = "\(c.name): \(event)"
            }
            if let app { apps[app, default: []].insert(c) }
        }
        return apps
    }

    /// A released meeting ends on the short wait when nothing still proves it: a native app's
    /// release is trusted, and a browser/Slack/calendar meeting is bound once its tab, huddle
    /// window or event is gone as well.
    func isBound(_ app: String, _ s: Snapshot) -> Bool {
        if KnownApps.native.contains(where: { $0.name == app }) { return true }
        let proof = Snapshot(micClients: Array(holders[app] ?? []), windowTitles: s.windowTitles,
                             calendarEvent: s.calendarEvent)
        return matches(in: proof)[app] == nil
    }

    public mutating func update(_ s: Snapshot, now: Double) -> [MeetingEvent] {
        if let last = lastWakeMarker, last != s.wakeMarker { wokeOrAudioRestarted(now: now) }
        if let last = lastDevices, last != s.devices { deviceChanged(now: now) }
        lastWakeMarker = s.wakeMarker
        lastDevices = s.devices

        let found = matches(in: s)
        var events: [MeetingEvent] = []
        for (app, clients) in found.sorted(by: { $0.key < $1.key }) {
            if !active.contains(app) {
                let since = pendingSince[app] ?? now
                pendingSince[app] = since
                guard now - since >= startAfter && now >= holdoffUntil else { continue }
                pendingSince[app] = nil
                startedAt[app] = now
                active.insert(app)
                events.append(.started(app: app))
            }
            holders[app, default: []].formUnion(clients)
        }
        // A candidate that drops out before startAfter starts over (flapping).
        for app in pendingSince.keys where found[app] == nil { pendingSince[app] = nil }
        for app in active.sorted() {
            // A running call stays on while its holder keeps the mic, even when its tab or window
            // is not visible: CGWindowList only reports a browser's front tab.
            if found[app] != nil || !(holders[app] ?? []).isDisjoint(with: s.micClients) {
                lostSince[app] = nil
                continue
            }
            let since = lostSince[app] ?? now
            lostSince[app] = since
            let wait = max(isBound(app, s) ? endWithEvidence : endWithoutEvidence, reacquire)
            if now - since >= wait && now - (startedAt[app] ?? now) >= minSession && now >= deviceGraceUntil {
                lostSince[app] = nil
                startedAt[app] = nil
                holders[app] = nil
                active.remove(app)
                events.append(.ended(app: app))
            }
        }
        return events
    }
}
