import Foundation

public enum MicTransport: String, Equatable {
    case builtIn, bluetooth, usb, virtual, other
}

/// An input device as CoreAudio lists it. `uid` survives reboots and replugging.
public struct MicDevice: Equatable {
    public let uid: String
    public let name: String
    public let transport: MicTransport

    public init(uid: String, name: String, transport: MicTransport) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }
}

public struct MicError: LocalizedError, Equatable {
    public let errorDescription: String?
    public static let noMic = MicError(errorDescription: "No microphone found")
    public static let lidClosed = MicError(errorDescription: "The lid is closed and no other mic is connected. Open the lid or plug in a mic.")
}

/// Which mic a dictation records from. Runs on every mic open.
public enum MicChoice {
    /// 1. the forced device, if present; 2. the first present device in the ranking; 3. the system default.
    /// With the lid closed the built-in mic is skipped (it is covered or switched off). Forced and ranked are the
    /// user's own choice; a virtual system default (a meeting app's loopback driver, an aggregate) is not, so it is
    /// never taken over a real mic: it records no voice. In its place comes the built-in mic, then the first other
    /// real one. Not CoreAudio's order alone: it can list an iPhone's Continuity mic before the built-in one.
    public static func pick(_ devices: [MicDevice], forced: String?, ranking: [String], systemDefault: String?,
                            lidClosed: Bool) throws -> MicDevice {
        let usable = lidClosed ? devices.filter { $0.transport != .builtIn } : devices
        guard let first = usable.first else { throw devices.isEmpty ? MicError.noMic : MicError.lidClosed }
        for uid in [forced].compactMap({ $0 }) + ranking {
            if let d = usable.first(where: { $0.uid == uid }) { return d }
        }
        let real = usable.first { $0.transport == .builtIn } ?? usable.first { $0.transport != .virtual }
        if let d = usable.first(where: { $0.uid == systemDefault }), d.transport != .virtual || real == nil { return d }
        return real ?? first
    }

    /// A new AVAudioEngine already records from the system default input. Moving it there anyway makes it
    /// reconfigure right after the start (the 21.10.26 empty recordings), so it is moved only to another device.
    public static func needsMove(_ pick: MicDevice, systemDefault: String?) -> Bool { pick.uid != systemDefault }

    /// "Prefer <name>": that device goes to the top of the ranking.
    public static func prefer(_ uid: String, in ranking: [String]) -> [String] {
        [uid] + ranking.filter { $0 != uid }
    }
}

/// Notices about the mic that span dictations, in our own words. The shell keeps `seen` and
/// `bluetoothHintShown` across launches.
public struct MicNotices {
    public private(set) var seen: Set<String>?  // nil before the first look: what is plugged in then is not new
    public private(set) var bluetoothHintShown: Bool
    private var current: String?

    public static let bluetoothHint = "Tip: the built-in mic records clearer than Bluetooth"

    public init(seen: Set<String>?, bluetoothHintShown: Bool) {
        self.seen = seen
        self.bluetoothHintShown = bluetoothHintShown
    }

    /// Call on every device-list change and mic open. "New mic: <name>" once per device ever,
    /// "Using <name>" when the pick moved to another device.
    public mutating func update(_ devices: [MicDevice], pick: MicDevice?) -> [String] {
        var out: [String] = []
        var known = seen ?? Set(devices.map(\.uid))
        for d in devices where !known.contains(d.uid) {
            known.insert(d.uid)
            out.append("New mic: \(d.name)")
        }
        seen = known
        if let pick {
            if let current, current != pick.uid { out.append("Using \(pick.name)") }
            current = pick.uid
        }
        return out
    }

    /// Once ever, when a dictation records from Bluetooth while a built-in mic could be used.
    public mutating func opening(_ pick: MicDevice, builtInUsable: Bool) -> String? {
        guard pick.transport == .bluetooth, builtInUsable, !bluetoothHintShown else { return nil }
        bluetoothHintShown = true
        return Self.bluetoothHint
    }
}

/// Watches one dictation's audio, fed one buffer at a time with its time (seconds, any monotonic clock),
/// and `tick` from a timer for the case where no buffer comes at all. Every value is a calibration knob.
/// Only exact zeros count as silence: that is a dead mic or driver, not a quiet room.
public struct MicHealth {
    public enum Event: Equatable {
        case reopen       // the start is silent: reopen the mic once
        case silent       // zeros for `warnAfter`: warn next to 🤫
        case stillSilent  // zeros for `escalateAfter`: a stronger warning
        case noAudio      // no buffer at all `noAudioAfter` after the start: stop, keep the audio, show an error
        case stalled      // buffers came, then none for `noAudioAfter`: stop, transcribe what came, show an error
    }

    public var reopenAfter: TimeInterval = 1
    public var warnAfter: TimeInterval = 5
    public var escalateAfter: TimeInterval = 15
    public var noAudioAfter: TimeInterval = 5

    private let start: TimeInterval
    private var last: TimeInterval?        // the newest buffer's time
    private var heard = false              // a non-zero sample since the start
    private var zerosSince: TimeInterval?
    private var fired: Set<Event> = []

    public init(start: TimeInterval) { self.start = start }

    public mutating func buffer(_ samples: UnsafeBufferPointer<Float>, at t: TimeInterval) -> [Event] {
        last = t
        if samples.contains(where: { $0 != 0 }) {
            heard = true
            zerosSince = nil
            return []
        }
        let since = zerosSince ?? (heard ? t : start)
        zerosSince = since
        var out: [Event] = []
        if !heard, t - since >= reopenAfter { out += once(.reopen) }
        if t - since >= warnAfter { out += once(.silent) }
        if t - since >= escalateAfter { out += once(.stillSilent) }
        return out
    }

    public mutating func buffer(_ samples: [Float], at t: TimeInterval) -> [Event] {
        samples.withUnsafeBufferPointer { buffer($0, at: t) }
    }

    public mutating func tick(at t: TimeInterval) -> [Event] {
        t - (last ?? start) >= noAudioAfter ? once(last == nil ? .noAudio : .stalled) : []
    }

    private mutating func once(_ e: Event) -> [Event] {
        fired.insert(e).inserted ? [e] : []
    }

    // MARK: finished recordings

    public static let quietHint = "Speak closer or use a wired mic"
    /// ponytail: whole-recording RMS, pauses included, stands in for Wispr's server-side SNR. About -50 dBFS:
    /// normal speech at a laptop mic sits near -30. Tune it with `defaults write io.backant.shepetal micQuietFloor`;
    /// a VAD-gated speech level and SNR replace it when local VAD lands.
    public static let quietFloor: Float = 0.003

    /// True for a recording that has sound (not a dead mic) but too little of it.
    public static func isQuiet(_ samples: [Float], floor: Float = quietFloor) -> Bool {
        guard !samples.isEmpty else { return false }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        return rms > 0 && rms < floor
    }
}
