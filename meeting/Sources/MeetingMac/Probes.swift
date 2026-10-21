#if canImport(CoreAudio)
import CoreAudio
import CoreMediaIO
import MeetingCore
import os

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr else { return nil }
    return ref?.takeRetainedValue() as String?
}

/// The object IDs, numbers and strings the probes read off a property graph: live Core Audio or CoreMediaIO, or a
/// test fixture. Object IDs and selectors are UInt32 in both frameworks.
struct PropertyReader: Sendable {
    var ids: @Sendable (UInt32, UInt32) -> [UInt32]
    var number: @Sendable (UInt32, UInt32) -> UInt32?
    var string: @Sendable (UInt32, UInt32) -> String? = { _, _ in nil }

    static let coreAudio = PropertyReader(ids: { object, selector in
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }, number: { read($0, $1, UInt32(0)) }, string: readString)

    static let coreMediaIO = PropertyReader(ids: { object, selector in
        var addr = Probes.cmio(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }, number: { object, selector in
        var addr = Probes.cmio(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr ? value : nil
    })
}

public enum Probes {
    /// Processes capturing audio input, via Core Audio process objects (macOS 14.2+), with their executables and
    /// the executable of the process responsible for each (a helper's app). Reads metadata only: no TCC prompt.
    public static func micUsers() -> [MicUser] { micUsers(.coreAudio) }

    /// `micUsers()` on any process list: tests pass a fixture of fake process objects.
    static func micUsers(_ r: PropertyReader) -> [MicUser] {
        r.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard r.number(id, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            let pid = pid_t(bitPattern: r.number(id, kAudioProcessPropertyPID) ?? 0)
            return MicUser(pid: pid, bundleID: r.string(id, kAudioProcessPropertyBundleID) ?? "",
                           path: path(pid), responsiblePath: path(responsible?(pid) ?? pid))
        }
    }

    static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    /// The process macOS holds responsible for a pid (Safari for its WebKit GPU process, Chrome for a helper), as
    /// Activity Monitor and TCC attribute them. Private libsystem SPI, so it is looked up and may be missing.
    static let responsible: (@convention(c) (pid_t) -> pid_t)? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
        "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }

    /// Whether any camera runs in some process, from CoreMediaIO device state. This reads no frames, so it needs
    /// no camera access and never prompts. macOS does not say which process it is.
    public static func cameraInUse() -> Bool { cameraInUse(.coreMediaIO) }

    /// `cameraInUse()` on any device list: tests pass a fixture of fake CMIO devices.
    static func cameraInUse(_ r: PropertyReader) -> Bool {
        r.ids(CMIOObjectID(kCMIOObjectSystemObject), CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)).contains {
            (r.number($0, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)) ?? 0) != 0
        }
    }

    static func cmio(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    /// Default input and output device IDs (no permission needed).
    public static func devices() -> [UInt32] {
        [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            read(AudioObjectID(kAudioObjectSystemObject), $0, AudioObjectID(0)) ?? 0
        }
    }

    static let audioRestarts = OSAllocatedUnfairLock(initialState: 0)
    static let restartListener: OSStatus = {
        var addr = address(kAudioHardwarePropertyServiceRestarted)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .global()) { _, _ in
            audioRestarts.withLock { $0 += 1 }
        }
    }()

    /// Last wake time (`kern.waketime`) plus the number of coreaudiod restarts seen.
    public static func wakeMarker() -> String {
        _ = restartListener
        var wake = timeval()
        var size = MemoryLayout<timeval>.size
        let ok = sysctlbyname("kern.waketime", &wake, &size, nil, 0) == 0
        return "\(ok ? wake.tv_sec : -1).\(wake.tv_usec)/\(audioRestarts.withLock { $0 })"
    }

    public static func snapshot() -> Snapshot {
        Snapshot(micUsers: micUsers(), cameraInUse: cameraInUse(), devices: devices(), wakeMarker: wakeMarker())
    }

    /// The detector `shepetal-meeting probe` and `watch` run. It skips this CLI by pid and the Shepetal app, whose
    /// dictation and meeting capture run in another process, by its exact bundle ID.
    public static func detector() -> MeetingDetector {
        MeetingDetector(ownPID: getpid(), ownBundleID: "io.backant.shepetal")
    }
}
#endif
