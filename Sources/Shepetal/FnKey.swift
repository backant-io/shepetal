import AppKit
import ShepetalCore

/// The real I/O for `FnKeySetting`: `defaults` for com.apple.HIToolbox (the same path System Settings'
/// value takes through cfprefsd), `killall` for the input agents that cache it, and Shepetal's own
/// defaults for the replaced value. Only the installed app (bundle ID io.backant.shepetal) uses it;
/// test bundles and the bare binary never touch the setting.
enum FnKeySystem {
    static var enabled: Bool { Bundle.main.bundleIdentifier == "io.backant.shepetal" }

    static let io = FnKeySetting.IO(
        read: {
            let r = run("/usr/bin/defaults", ["read", FnKeySetting.domain, FnKeySetting.key])
            return r.status == 0 ? Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        },
        write: { value in
            if let value {
                _ = run("/usr/bin/defaults", ["write", FnKeySetting.domain, FnKeySetting.key, "-int", String(value)])
            } else {
                _ = run("/usr/bin/defaults", ["delete", FnKeySetting.domain, FnKeySetting.key])
            }
        },
        restartInputAgents: {
            _ = run("/usr/bin/killall", ["TextInputMenuAgent"])
            _ = run("/usr/bin/killall", ["-9", "TextInputSwitcher"])  // ignores SIGTERM; launchd restarts it
        },
        loadPrevious: { UserDefaults.standard.object(forKey: FnKeySetting.previousKey) as? Int },
        storePrevious: { value in
            if let value { UserDefaults.standard.set(value, forKey: FnKeySetting.previousKey) } else {
                UserDefaults.standard.removeObject(forKey: FnKeySetting.previousKey)
            }
        },
        takeNoticePending: {
            defer { UserDefaults.standard.removeObject(forKey: FnKeySetting.noticePendingKey) }
            return UserDefaults.standard.bool(forKey: FnKeySetting.noticePendingKey)
        })

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// What is wrong with fn right now, for the Home tab and the 🤫 hint. nil when nothing is known to be wrong.
@MainActor
enum FnDiagnostics {
    static var problem: String?
}

/// Polls the HID state of the fn key itself (keycode 63, or Globe 179; not the fn flag, which macOS also
/// sets for arrows, F-keys and Home/End) and reports a press the event tap never delivered. It only
/// polls while `active()` (the tap is running): without Input Monitoring the permission prompt speaks.
@MainActor
final class FnWatch {
    private var health = FnHealth()
    private var timer: Timer?
    var onUnreported: (() -> Void)?
    var active: () -> Bool = { false }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let down = self.active() && (CGEventSource.keyState(.hidSystemState, key: 63)
                                             || CGEventSource.keyState(.hidSystemState, key: 179))
                if self.health.poll(hidFnDown: down, at: ProcessInfo.processInfo.systemUptime) { self.onUnreported?() }
            }
        }
    }

    func tapEvent() { health.tapEvent(at: ProcessInfo.processInfo.systemUptime) }
}
