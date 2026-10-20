#if canImport(CoreAudio)
import AppKit
import CoreAudio
import MeetingCore

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

public enum Probes {
    /// Processes currently capturing audio input, via Core Audio process objects (macOS 14.2+).
    /// Reads metadata only: no TCC prompt.
    public static func micClients() -> [MicClient] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard read(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1 else { return nil }
            let pid = read(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0
            return MicClient(bundleID: readString(id, kAudioProcessPropertyBundleID) ?? "", name: processName(pid))
        }
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.split(separator: "/").last.map(String.init) ?? "pid \(pid)"
    }

    /// On-screen window titles keyed by owner bundle ID. macOS only returns titles of other
    /// apps with Screen Recording permission; we check first so this never prompts.
    public static func windowTitles() -> [String: [String]] {
        guard CGPreflightScreenCaptureAccess(),
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var out: [String: [String]] = [:]
        for w in list {
            guard let title = w[kCGWindowName as String] as? String, !title.isEmpty,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
            out[bundle, default: []].append(title)
        }
        return out
    }

    public static func snapshot() -> Snapshot {
        Snapshot(micClients: micClients(), windowTitles: windowTitles())
    }
}
#endif
