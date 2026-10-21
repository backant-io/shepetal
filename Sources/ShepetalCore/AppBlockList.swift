import Foundation

/// The apps where fn does not dictate (games, remote desktops, apps that use fn themselves), turned off from the
/// 🤫 menu. Kept in UserDefaults as bundle id → app name; the name is only for the menu and the hint.
public struct AppBlockList {
    public static let key = "dictationOffApps"
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Bundle id → name. Read entry by entry: a bad value drops only itself.
    public var apps: [String: String] { (defaults.dictionary(forKey: Self.key) ?? [:]).compactMapValues { $0 as? String } }

    /// Exact bundle id. An empty one (no front app, or an app without a bundle) is never blocked.
    public func blocks(bundleId: String) -> Bool { !bundleId.isEmpty && apps[bundleId] != nil }

    public func set(_ bundleId: String, name: String, off: Bool) {
        guard !bundleId.isEmpty else { return }
        var apps = apps
        apps[bundleId] = off ? (name.isEmpty ? bundleId : name) : nil
        defaults.set(apps, forKey: Self.key)
    }

    /// The gate on fn: the hint shown instead of dictating, or nil to go on. Only a press that would start a
    /// dictation is stopped; ending one (fn up, the toggle while hands-free, Esc) always goes through.
    /// Nothing is swallowed for it: fn is a modifier, so the front app gets it as usual.
    public func hint(for input: KeyInput, idle: Bool, bundleId: String, name: String) -> String? {
        guard idle, input == .pttDown || input == .toggle, blocks(bundleId: bundleId) else { return nil }
        return Self.hint(name.isEmpty ? apps[bundleId] ?? bundleId : name)
    }

    public static func hint(_ app: String) -> String { "Dictation is off in \(app)" }
}
