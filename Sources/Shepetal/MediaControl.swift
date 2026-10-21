import AppKit
import AudioToolbox
import CoreAudio
import ShepetalCore

/// F09 on the Mac: reads Core Audio for `MediaPolicy` and carries out what it returns. Mute uses the default
/// output's mute, or its volume where there is no settable mute; pause posts the play/pause media key, which needs
/// the Accessibility grant the paste already uses. All public API.
@MainActor
final class MediaControl {
    nonisolated static let muteKey = "media.muteWhileDictating"
    nonisolated static let pauseKey = "media.pauseWhileDictating"

    struct System {
        var processes: () -> [AudioProcess]
        var output: (_ uid: String?) -> OutputDevice?  // nil: the default output device
        var apply: (MediaAction) -> Void
    }

    private var policy = MediaPolicy(ownPID: getpid(), ownBundleID: Bundle.main.bundleIdentifier ?? "io.backant.shepetal")
    private let system: System
    private let defaults: UserDefaults
    private let meeting: () -> Bool
    /// How long after the pause key `MediaPolicy.check` looks for a player the key started.
    var settle: TimeInterval = 1
    private var pending: [DispatchWorkItem] = []

    /// `meeting`: a meeting records or is detected; nothing is muted or paused then.
    init(system: System = .live, defaults: UserDefaults = .standard, meeting: @escaping () -> Bool) {
        self.system = system
        self.defaults = defaults
        self.meeting = meeting
    }

    /// Call on the gesture's `.start` with its hold threshold (mute) and chord window (pause), and again on
    /// `.lockHandsFree` with 0 and 0. Each step acts once `live()` says fn is held or hands-free, so a short tap
    /// never acts, and fn as a modifier (fn+Delete, fn+arrow, which cancel up to the chord window) never presses
    /// the pause key. Mute may come earlier: its restore reads the device exactly. Each step acts once per
    /// dictation, so the lock's second call does not act again.
    func begin(mute muteDelay: TimeInterval, pause pauseDelay: TimeInterval, live: @escaping () -> Bool) {
        policy.mute = defaults.bool(forKey: Self.muteKey)
        policy.pause = defaults.bool(forKey: Self.pauseKey)
        after(muteDelay) { me in
            guard live() else { return }
            me.policy.startMute(processes: me.system.processes(), output: me.system.output(nil), meeting: me.meeting())
                .forEach(me.system.apply)
        }
        after(pauseDelay) { me in
            guard live() else { return }
            let actions = me.policy.startPause(processes: me.system.processes(), meeting: me.meeting())
            actions.forEach(me.system.apply)
            guard !actions.isEmpty else { return }
            me.after(me.settle) { $0.policy.check(processes: $0.system.processes()).forEach($0.system.apply) }
        }
    }

    /// Call on stop, cancel, too short, a failed end and quit: restores what this dictation muted or paused.
    func end() {
        pending.forEach { $0.cancel() }
        pending = []
        policy.stop(processes: system.processes(), device: { system.output($0) }).forEach(system.apply)
    }

    private func after(_ delay: TimeInterval, _ body: @escaping @MainActor (MediaControl) -> Void) {
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if let self { body(self) } } }
        pending.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension MediaControl.System {
    static var live: Self { Self(processes: CoreAudioMedia.processes, output: CoreAudioMedia.output, apply: CoreAudioMedia.apply) }
}

private enum CoreAudioMedia {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let out = kAudioDevicePropertyScopeOutput
    static let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    static func processes() -> [AudioProcess] {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioProcess(pid: read(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0,
                         bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                         output: read(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1,
                         input: read(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1)
        }
    }

    static func output(_ uid: String?) -> OutputDevice? {
        let found = uid.map { AudioDevices.id(forUID: $0) } ?? read(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        guard let id = found, id != kAudioObjectUnknown, let uid = uid ?? string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return OutputDevice(uid: uid, muted: read(id, kAudioDevicePropertyMute, UInt32(0), out).map { $0 != 0 },
                            volume: read(id, volume, Float32(0), out),
                            canMute: settable(id, kAudioDevicePropertyMute), canSetVolume: settable(id, volume))
    }

    static func apply(_ action: MediaAction) {
        switch action {
        case .setMute(let uid, let on): if let id = AudioDevices.id(forUID: uid) { write(id, kAudioDevicePropertyMute, UInt32(on ? 1 : 0)) }
        case .setVolume(let uid, let v): if let id = AudioDevices.id(forUID: uid) { write(id, volume, Float32(v)) }
        case .playPause: playPause()
        }
    }

    /// NX_KEYTYPE_PLAY (16) down then up, as the keyboard's play/pause key sends it; macOS hands it to the
    /// app that is playing now.
    static func playPause() {
        for state in [0xa, 0xb] {
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (16 << 16) | (state << 8), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var a = address(selector, scope)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }

    static func settable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var a = address(selector, out)
        var ok: DarwinBoolean = false
        return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &ok) == noErr && ok.boolValue
    }

    static func write<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) {
        var a = address(selector, out)
        var v = value
        let status = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
        if status != noErr { NSLog("shepetal: media: setting %u on device %u failed (%d)", selector, id, status) }
    }
}
