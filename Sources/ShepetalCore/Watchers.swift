/// Turns permission polls into revocations (docs/re/app-architecture.md 5, dictation-input.md 2.9).
/// The first poll only records: a permission missing at launch is onboarding, not a revocation.
public struct PermissionWatch<P: Hashable> {
    private var granted: [P: Bool]?

    public init() {}

    /// Returns the permissions that went from granted to missing since the last poll.
    public mutating func observe(_ now: [P: Bool]) -> [P] {
        defer { granted = now }
        guard let granted else { return [] }
        return now.filter { !$0.value && granted[$0.key] == true }.map(\.key)
    }

    public static func message(_ permission: String) -> String { "\(permission) access was turned off" }
}

/// Secure input (a focused password field, or Terminal's Secure Keyboard Entry) hides every keystroke
/// from other apps, fn included (dictation-input.md 2.2, insertion-context.md 2.8, 4 M6).
/// Notifies once when it turns on and clears when it turns off. Shepetal's own secure input is ignored.
public struct SecureInputWatch {
    public enum Change: Equatable { case on(String), off }
    public private(set) var isOn = false

    public init() {}

    public static func blocks(enabled: Bool, ownerPid: Int32?, selfPid: Int32) -> Bool {
        enabled && ownerPid != selfPid
    }

    /// One poll. `ownerName` is the app holding secure input, nil when it cannot be named.
    public mutating func poll(enabled: Bool, ownerPid: Int32?, ownerName: String?, selfPid: Int32) -> Change? {
        let on = Self.blocks(enabled: enabled, ownerPid: ownerPid, selfPid: selfPid)
        defer { isOn = on }
        if on == isOn { return nil }
        return on ? .on(Self.notice(Self.appName(ownerName))) : .off
    }

    public static func appName(_ name: String?) -> String { name ?? "another app" }
    public static func notice(_ app: String) -> String { "Secure input is on in \(app), so fn can't be heard" }
    public static func pasteMessage(_ app: String) -> String { "Secure input is on in \(app). The text is in Recent." }
}

/// "Open at login" menu state from `SMAppService.Status` (app-architecture.md 4, `openAtLogin`).
public enum LoginItemStatus { case enabled, notRegistered, requiresApproval, notFound }

public enum LoginItemMenu {
    public static let approval = "Allow Shepetal in System Settings > General > Login Items"

    public static func state(_ status: LoginItemStatus) -> (checked: Bool, message: String?) {
        switch status {
        case .enabled: (true, nil)
        case .requiresApproval: (false, approval)
        case .notRegistered, .notFound: (false, nil)
        }
    }
}
