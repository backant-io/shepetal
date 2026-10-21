/// A process that is currently capturing audio input.
public struct MicUser: Hashable, Sendable {
    public var pid: Int32
    public var bundleID: String
    /// Its executable, and the executable of the process macOS holds responsible for it (Safari for its WebKit
    /// GPU process). Both name the app on the card; neither is ever logged with more than that name.
    public var path: String
    public var responsiblePath: String
    public init(pid: Int32, bundleID: String = "", path: String, responsiblePath: String = "") {
        self.pid = pid
        self.bundleID = bundleID
        self.path = path
        self.responsiblePath = responsiblePath
    }
}

/// One observation of the system, taken about once a second.
public struct Snapshot: Sendable {
    public var micUsers: [MicUser]
    /// Some process is running a camera. macOS does not say which one.
    public var cameraInUse: Bool
    /// Default input and output devices. A change starts the device-change grace.
    public var devices: [UInt32]
    /// Changes on system wake or an audio server restart (Mac: kern.waketime + coreaudiod
    /// restart count). A change starts the holdoff.
    public var wakeMarker: String

    public init(micUsers: [MicUser] = [], cameraInUse: Bool = false, devices: [UInt32] = [], wakeMarker: String = "") {
        self.micUsers = micUsers
        self.cameraInUse = cameraInUse
        self.devices = devices
        self.wakeMarker = wakeMarker
    }
}

public enum MeetingEvent: Equatable, Sendable {
    case started(app: String)
    case ended(app: String)
}

/// Pavel's rule (2026-10-21): another app using the mic or the camera is a possible meeting. No app lists, no
/// window titles, no Screen Recording. Pure state machine: the caller supplies the clock, so it is fully testable.
public struct MeetingDetector: Sendable {
    /// Seconds the mic or camera must be in use before a meeting starts (grace).
    public var startAfter: Double = 5
    /// No starts this long after wake or a Core Audio restart.
    public var holdoff: Double = 10
    /// No end in the first seconds of a meeting.
    public var minSession: Double = 15
    /// Seconds with neither mic nor camera in use before the meeting ends; use coming back sooner is the same meeting.
    public var endAfter: Double = 4
    /// An audio device change suppresses ends for this long.
    public var deviceChangeGrace: Double = 10
    /// Shepetal itself (dictation, meeting capture) never counts. Matched exactly, never by name.
    public var ownPID: Int32
    public var ownBundleID: String?

    private var usedSince: Double?
    private var releasedSince: Double?
    private var startedAt = 0.0
    private var holdoffUntil = -Double.infinity
    private var deviceGraceUntil = -Double.infinity
    private var lastDevices: [UInt32]?
    private var lastWakeMarker: String?
    /// The card label of the running meeting; nil when there is none.
    public private(set) var active: String?

    public init(ownPID: Int32, ownBundleID: String? = nil) {
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    /// Call after system wake or a coreaudiod restart (`update` does this when `wakeMarker` changes).
    public mutating func wokeOrAudioRestarted(now: Double) { holdoffUntil = now + holdoff }
    /// Call when the default input/output device changes (`update` does this when `devices` change).
    public mutating func deviceChanged(now: Double) { deviceGraceUntil = now + deviceChangeGrace }

    /// What the card names for `s`: the first other app on the mic, else "Microphone" or "Camera"; nil when
    /// neither is in use by anyone but Shepetal.
    public func app(in s: Snapshot) -> String? {
        let others = s.micUsers.filter { $0.pid != ownPID && $0.bundleID != ownBundleID }
        if let name = others.lazy.compactMap({ Self.appName($0.path) ?? Self.appName($0.responsiblePath) }).first {
            return name
        }
        return !others.isEmpty ? "Microphone" : s.cameraInUse ? "Camera" : nil
    }

    /// The outermost app bundle in `path`, so a helper is named after its app: "Google Chrome" for
    /// /Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper.
    public static func appName(_ path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") && $0.count > 4 }.map { String($0.dropLast(4)) }
    }

    public mutating func update(_ s: Snapshot, now: Double) -> [MeetingEvent] {
        if let last = lastWakeMarker, last != s.wakeMarker { wokeOrAudioRestarted(now: now) }
        if let last = lastDevices, last != s.devices { deviceChanged(now: now) }
        lastWakeMarker = s.wakeMarker
        lastDevices = s.devices

        let app = app(in: s)
        if let current = active {
            guard app == nil else { releasedSince = nil; return [] }
            let since = releasedSince ?? now
            releasedSince = since
            guard now - since >= endAfter, now - startedAt >= minSession, now >= deviceGraceUntil else { return [] }
            active = nil
            releasedSince = nil
            return [.ended(app: current)]
        }
        // Use that stops before startAfter starts over (flapping).
        guard let app else { usedSince = nil; return [] }
        let since = usedSince ?? now
        usedSince = since
        guard now - since >= startAfter, now >= holdoffUntil else { return [] }
        usedSince = nil
        startedAt = now
        active = app
        return [.started(app: app)]
    }
}
