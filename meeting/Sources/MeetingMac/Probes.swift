#if canImport(CoreAudio)
import AppKit
import CoreAudio
import EventKit
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

    nonisolated(unsafe) static let eventStore = EKEventStore()

    /// The calendar event around now. Reads EventKit only when Calendar full access is already
    /// granted, so this never prompts.
    public static func calendarEvent(now: Date = Date()) -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let window = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-300),
                                                   end: now.addingTimeInterval(300), calendars: nil)
        let events = eventStore.events(matching: window).map {
            CalendarEvent(title: $0.title ?? "", start: $0.startDate.timeIntervalSince1970,
                          end: $0.endDate.timeIntervalSince1970, isAllDay: $0.isAllDay)
        }
        return CalendarEvent.current(in: events, now: now.timeIntervalSince1970)
    }

    public static func snapshot() -> Snapshot {
        Snapshot(micClients: micClients(), windowTitles: windowTitles(), calendarEvent: calendarEvent(),
                 devices: devices(), wakeMarker: wakeMarker())
    }
}
#endif
