/// A process in Core Audio's process-object list (`kAudioHardwarePropertyProcessObjectList`).
public struct AudioProcess: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    public var output: Bool  // kAudioProcessPropertyIsRunningOutput
    public var input: Bool   // kAudioProcessPropertyIsRunningInput

    public init(pid: Int32, bundleID: String = "", output: Bool = false, input: Bool = false) {
        self.pid = pid; self.bundleID = bundleID; self.output = output; self.input = input
    }
}

/// An output device as read just now. `muted` and `volume` are nil when the device has no such control or it
/// could not be read.
public struct OutputDevice: Equatable, Sendable {
    public var uid: String
    public var muted: Bool?
    public var volume: Float?
    public var canMute: Bool
    public var canSetVolume: Bool

    public init(uid: String, muted: Bool?, volume: Float?, canMute: Bool = true, canSetVolume: Bool = true) {
        self.uid = uid; self.muted = muted; self.volume = volume; self.canMute = canMute; self.canSetVolume = canSetVolume
    }
}

public enum MediaAction: Equatable, Sendable {
    case setMute(uid: String, Bool)
    case setVolume(uid: String, Float)
    case playPause  // the media play/pause key
}

/// F09: "Mute other audio while dictating" and "Pause media while dictating", both off by default (Wispr's Mac
/// defaults, docs/re/dictation-input.md 2.6). Pure: the shell reads Core Audio, calls `start` and `stop` once per
/// dictation and carries out the actions they return.
public struct MediaPolicy: Sendable {
    public var mute = false
    public var pause = false
    let ownPID: Int32
    let ownBundleID: String
    enum Restore: Equatable { case unmute, volume(Float) }
    /// The one device this dictation silenced, by UID, and how to undo it.
    private(set) var owed: (uid: String, restore: Restore)?
    /// The processes playing when we sent pause.
    private(set) var paused: Set<Int32> = []
    private var started = false

    public init(ownPID: Int32, ownBundleID: String) {
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    /// The dictation started. `output` is the default output device; `meeting` is true while a meeting records
    /// or one is detected. A second call before `stop` does nothing, so a second pause key cannot restart the media.
    public mutating func start(processes: [AudioProcess], output: OutputDevice?, meeting: Bool) -> [MediaAction] {
        guard !started else { return [] }
        started = true
        let others = processes.filter { $0.pid != ownPID && $0.bundleID != ownBundleID }
        // A call app holds the mic: muting or pausing would cut the call.
        guard !meeting, !others.contains(where: \.input) else { return [] }
        let playing = others.filter(\.output)
        guard !playing.isEmpty else { return [] }
        var actions: [MediaAction] = []
        if pause {
            paused = Set(playing.map(\.pid))
            actions.append(.playPause)
        }
        // Already silent, or unreadable: leave it alone and owe nothing.
        if mute, let o = output, o.muted != true, o.volume != 0 {
            if o.muted == false, o.canMute {
                owed = (o.uid, .unmute)
                actions.append(.setMute(uid: o.uid, true))
            } else if let v = o.volume, o.canSetVolume {
                owed = (o.uid, .volume(v))
                actions.append(.setVolume(uid: o.uid, 0))
            }
        }
        return actions
    }

    /// The dictation ended (stop, cancel, too short, mic lost). `device` reads a device by UID now; `processes`
    /// is read only when something was paused.
    public mutating func stop(processes: @autoclosure () -> [AudioProcess],
                              device: (String) -> OutputDevice?) -> [MediaAction] {
        defer { started = false; owed = nil; paused = [] }
        var actions: [MediaAction] = []
        // Only the device we silenced, and only if it is still the way we left it: a user who changed it wins.
        if let (uid, restore) = owed, let d = device(uid) {
            switch restore {
            case .unmute where d.muted == true: actions.append(.setMute(uid: uid, false))
            case .volume(let v) where d.volume == 0: actions.append(.setVolume(uid: uid, v))
            default: break
            }
        }
        // ponytail: "stopped" is read from Core Audio, so a player that keeps its output running for a while after a
        // pause (browsers can) is not resumed after a short dictation. Reading now-playing needs a MediaRemote
        // adapter since macOS 15.4; add one if the hand test shows this.
        if !paused.isEmpty {
            let stillPlaying = Set(processes().filter(\.output).map(\.pid))
            if !paused.isSubset(of: stillPlaying) { actions.append(.playPause) }
        }
        return actions
    }
}
