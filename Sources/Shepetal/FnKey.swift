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

/// Says "fn not received" only on evidence (`FnHealth`): the 🌐 key's 179 reached the tap, fn's 63 did not.
/// Fed from the tap's events on the main thread; checks once `FnHealth.window` after each 🌐 press.
@MainActor
final class FnWatch {
    private var health = FnHealth()
    var onUnreported: (() -> Void)?

    func fn(down: Bool, at t: TimeInterval) { health.fn(down: down, at: t) }

    func globe(at t: TimeInterval) {
        health.globe(at: t)
        DispatchQueue.main.asyncAfter(deadline: .now() + FnHealth.window) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.health.poll(at: ProcessInfo.processInfo.systemUptime) else { return }
                self.onUnreported?()
            }
        }
    }
}
