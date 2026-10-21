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
/// defaults, docs/re/dictation-input.md 2.6). Pure: the shell reads Core Audio, calls each step at its time in a
/// dictation and carries out the actions it returns.
public struct MediaPolicy: Sendable {
    public var mute = false
    public var pause = false
    let ownPID: Int32
    let ownBundleID: String
    enum Restore: Equatable { case unmute, volume(Float) }
    /// The one device this dictation silenced, by UID, and how to undo it.
    private(set) var owed: (uid: String, restore: Restore)?
    /// The other apps running output when we sent the pause key.
    private(set) var paused: Set<Int32> = []
    private var muteStarted = false, pauseStarted = false

    public init(ownPID: Int32, ownBundleID: String) {
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    /// fn held past the hold threshold, or hands-free: mutes the default output `output` if another app is
    /// playing. `meeting` is true while a meeting records or one is detected. Once per dictation, so the hands-free
    /// lock cannot act twice; `processes` and `output` are read only when mute is on.
    public mutating func startMute(processes: @autoclosure () -> [AudioProcess], output: @autoclosure () -> OutputDevice?,
                                   meeting: Bool) -> [MediaAction] {
        guard mute, !muteStarted else { return [] }
        muteStarted = true
        // Already silent, or unreadable: leave it alone and owe nothing.
        guard !playing(processes(), meeting: meeting).isEmpty, let o = output(), o.muted != true, o.volume != 0 else { return [] }
        if o.muted == false, o.canMute {
            owed = (o.uid, .unmute)
            return [.setMute(uid: o.uid, true)]
        }
        if let v = o.volume, o.canSetVolume {
            owed = (o.uid, .volume(v))
            return [.setVolume(uid: o.uid, 0)]
        }
        return []
    }

    /// fn held past the chord window (fn+key can no longer cancel), or hands-free: the play/pause key if another
    /// app is playing. Once per dictation, so a second key cannot restart the media; `processes` is read only when
    /// pause is on.
    public mutating func startPause(processes: @autoclosure () -> [AudioProcess], meeting: Bool) -> [MediaAction] {
        guard pause, !pauseStarted else { return [] }
        pauseStarted = true
        paused = playing(processes(), meeting: meeting)
        return paused.isEmpty ? [] : [.playPause]
    }

    /// About a second after the pause key. The key toggles: if nothing that was playing has stopped but another
    /// app now runs output, the key started that app (Music while a game held the output), so press it again
    /// before it plays into the whole recording. Nothing is left to resume.
    public mutating func check(processes: [AudioProcess]) -> [MediaAction] {
        let now = running(processes)
        guard !paused.isEmpty, paused.isSubset(of: now), !now.isSubset(of: paused) else { return [] }
        paused = []
        return [.playPause]
    }

    /// The dictation ended (stop, cancel, too short, mic lost). `device` reads a device by UID now; `processes`
    /// is read only when something was paused.
    public mutating func stop(processes: @autoclosure () -> [AudioProcess],
                              device: (String) -> OutputDevice?) -> [MediaAction] {
        defer { muteStarted = false; pauseStarted = false; owed = nil; paused = [] }
        var actions: [MediaAction] = []
        // Only the device we silenced, and only if it is still the way we left it: a user who changed it wins.
        if let (uid, restore) = owed, let d = device(uid) {
            switch restore {
            case .unmute where d.muted == true: actions.append(.setMute(uid: uid, false))
            case .volume(let v) where d.volume == 0: actions.append(.setVolume(uid: uid, v))
            default: break
            }
        }
        // Press the key again when the set of players changed: one we paused has stopped (resume it), or one that
        // was silent now plays (the key started it).
        // ponytail: "playing" is Core Audio's running output, not "media is playing", and the key is a blind
        // toggle. So: (a) a browser keeps its output running for some seconds after a pause, which cannot be told
        // apart from playing. A tab we paused stays paused after a short dictation, and a video the user paused
        // just before dictating is started by the key and keeps playing. (b) A player whose output still runs at
        // the release stays paused, so a hold released soon after the pause (which comes 1 s in) can leave Music
        // paused too. (c) With nothing registered as now playing, the key can open Music.app, which may take
        // focus; the paste gate then skips the paste and the text stays for Cmd+V. All three need now-playing
        // state, which needs a MediaRemote adapter since macOS 15.4. Add one if the hand test shows them.
        if !paused.isEmpty, running(processes()) != paused { actions.append(.playPause) }
        return actions
    }

    private func others(_ processes: [AudioProcess]) -> [AudioProcess] {
        processes.filter { $0.pid != ownPID && $0.bundleID != ownBundleID }
    }

    /// Other apps running audio output now.
    private func running(_ processes: [AudioProcess]) -> Set<Int32> { Set(others(processes).filter(\.output).map(\.pid)) }

    /// Other apps running output, but none during a meeting or while another app holds the mic (a call):
    /// muting or pausing would cut the call.
    private func playing(_ processes: [AudioProcess], meeting: Bool) -> Set<Int32> {
        guard !meeting, !others(processes).contains(where: \.input) else { return [] }
        return running(processes)
    }
}
