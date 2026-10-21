import Foundation

/// After an update, say once that something is new. A first install, a relaunch and a downgrade say nothing.
public enum WhatsNew {
    /// The last version that ran on this Mac, in shepetal's own defaults.
    public static let defaultsKey = "lastSeenVersion"
    /// 0.1.0 recorded no version, so data on this Mac without a recorded version means 0.1.0 ran here.
    public static let unrecorded = "0.1.0"

    /// `current` when it is newer than `lastSeen`. nil on a first install (no `lastSeen`), a relaunch or a downgrade.
    public static func announce(lastSeen: String?, current: String) -> String? {
        guard let lastSeen, isNewer(current, than: lastSeen) else { return nil }
        return current
    }

    /// Part by part, as numbers: 0.1.10 is newer than 0.1.9.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// At launch: reads the last version, records `current`, and returns the version to announce, if any.
    /// `hadData`: shepetal's data was on this Mac before this launch (an update from 0.1.0, not a first install).
    public static func launch(current: String, hadData: Bool, defaults: UserDefaults = .standard) -> String? {
        let last = defaults.string(forKey: defaultsKey) ?? (hadData ? unrecorded : nil)
        defaults.set(current, forKey: defaultsKey)
        return announce(lastSeen: last, current: current)
    }

    /// Next to the corner 🤫, once after an update. Nothing opens and nothing takes focus (rule 8).
    public static func hint(_ version: String) -> String { "Updated to \(version) · What's new is in the 🤫 menu" }
}
