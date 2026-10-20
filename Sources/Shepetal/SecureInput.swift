import AppKit
import Carbon
import ShepetalCore

/// Secure input: while another app has it on, fn can't be heard and a paste could land in a password field.
@MainActor
final class SecureInput {
    private var watch = SecureInputWatch()
    private var shown: String?
    private let indicator: Indicator

    init(indicator: Indicator) { self.indicator = indicator }

    /// One poll (the 2 s timer): a note next to 🤫 when it turns on, cleared when it turns off.
    func check() {
        let (enabled, pid) = Self.state()
        switch watch.poll(enabled: enabled, ownerPid: pid, ownerName: enabled ? Self.name(pid) : nil, selfPid: getpid()) {
        case .on(let text)?:
            shown = text
            indicator.show(text, seconds: 6)
        case .off?:
            if let shown, indicator.labelText == shown { indicator.show(shown, seconds: 0) }
            shown = nil
        case nil: break
        }
    }

    /// Paste-time check: the name of the app holding secure input, nil when the paste may go ahead.
    static func blocker() -> String? {
        let (enabled, pid) = state()
        guard SecureInputWatch.blocks(enabled: enabled, ownerPid: pid, selfPid: getpid()) else { return nil }
        return SecureInputWatch.appName(name(pid))
    }

    /// Whether secure input is on, and the pid holding it (`kCGSSessionSecureInputPID` in the session dictionary).
    private static func state() -> (Bool, Int32?) {
        guard IsSecureEventInputEnabled() else { return (false, nil) }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (true, (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value)
    }

    private static func name(_ pid: Int32?) -> String? {
        pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }
}
