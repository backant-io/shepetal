import Foundation

/// macOS "Press 🌐 key to" (com.apple.HIToolbox AppleFnUsageType: 0 Do Nothing, 1 Change Input Source,
/// 2 Show Emoji & Symbols, 3 Start Dictation). Anything but 0 makes fn do something of its own, so
/// dictation with fn never starts. Shepetal sets it to 0 at install and at every launch, keeps the
/// value it replaced (once) so the menu and the uninstaller can put it back, and touches nothing else.
///
/// All I/O is injected, so tests never read or write the real setting.
public enum FnKeySetting {
    public static let domain = "com.apple.HIToolbox"
    public static let key = "AppleFnUsageType"
    /// Where the replaced value is kept, in Shepetal's own defaults. `unset` means the key was absent.
    public static let previousKey = "previousAppleFnUsageType"
    public static let unset = -1
    /// Set by the installer's postinstall when it changed the value, so the app's next launch says so.
    public static let noticePendingKey = "fnKeyNoticePending"
    public static let doNothing = 0

    public static let changedHint = "🌐 key set to Do Nothing so fn can dictate"
    public static let failedHint = "Set Press 🌐 key to Do Nothing"

    public struct IO {
        /// The current AppleFnUsageType, nil when the key is absent.
        public var read: () -> Int?
        /// Writes AppleFnUsageType (nil deletes the key).
        public var write: (Int?) -> Void
        /// Restarts the processes that cache the value: TextInputMenuAgent, then TextInputSwitcher
        /// (which ignores SIGTERM, so it gets SIGKILL; launchd starts it again on demand).
        public var restartInputAgents: () -> Void
        public var loadPrevious: () -> Int?
        public var storePrevious: (Int?) -> Void
        /// Reads and clears the installer's "I changed it" flag.
        public var takeNoticePending: () -> Bool

        public init(read: @escaping () -> Int?, write: @escaping (Int?) -> Void, restartInputAgents: @escaping () -> Void,
                    loadPrevious: @escaping () -> Int?, storePrevious: @escaping (Int?) -> Void,
                    takeNoticePending: @escaping () -> Bool = { false }) {
            self.read = read
            self.write = write
            self.restartInputAgents = restartInputAgents
            self.loadPrevious = loadPrevious
            self.storePrevious = storePrevious
            self.takeNoticePending = takeNoticePending
        }
    }

    public enum Outcome: Equatable {
        /// Already Do Nothing: nothing written, nothing said.
        case alreadySet
        /// Already Do Nothing because the installer just changed it: nothing written, but said once.
        case changedByInstaller
        /// Was `from` (nil: absent), is 0 now, read back.
        case changed(from: Int?)
        /// Wrote 0 but read back something else.
        case failed(readBack: Int?)

        /// The text next to 🤫, or nil to stay silent.
        public var hint: String? {
            switch self {
            case .alreadySet: nil
            case .changed, .changedByInstaller: FnKeySetting.changedHint
            case .failed: FnKeySetting.failedHint
            }
        }
    }

    /// Run at every launch (and by the installer).
    public static func apply(_ io: IO) -> Outcome {
        let current = io.read()
        let installerChanged = io.takeNoticePending()
        guard current != doNothing else { return installerChanged ? .changedByInstaller : .alreadySet }
        if io.loadPrevious() == nil { io.storePrevious(current ?? unset) }  // the first replaced value only
        io.write(doNothing)
        io.restartInputAgents()
        let readBack = io.read()
        return readBack == doNothing ? .changed(from: current) : .failed(readBack: readBack)
    }

    /// The value "Restore 🌐 key setting" would put back, or nil when Shepetal never changed it.
    public static func restorable(_ io: IO) -> Int? { io.loadPrevious() }

    /// Puts the replaced value back and forgets it. Returns false when there was nothing to restore.
    @discardableResult
    public static func restore(_ io: IO) -> Bool {
        guard let previous = io.loadPrevious() else { return false }
        io.write(previous == unset ? nil : previous)
        io.restartInputAgents()
        io.storePrevious(nil)
        return true
    }

    public static func describe(_ value: Int?) -> String {
        switch value {
        case nil, unset?: "the macOS default"
        case 0?: "Do Nothing"
        case 1?: "Change Input Source"
        case 2?: "Show Emoji & Symbols"
        case 3?: "Start Dictation"
        case let v?: "value \(v)"
        }
    }
}

/// Notices fn not reaching the tap, from the tap's own events only: the 🌐 key's keycode 179 keyDown arrived (so
/// the key was pressed and the tap is alive) but no fn flagsChanged (keycode 63) came within `window` of it.
/// Typing, modifiers and shortcuts never send 179, so they never alert. It cannot see a tap that gets nothing at
/// all; a tap macOS refuses says `hint` (App), and a revoked permission says so itself (PermissionMonitor).
/// (The HID state it used to poll was wrong: the fn flag is also set for arrows and F-keys.)
public struct FnHealth {
    public static let window: TimeInterval = 1.0
    /// The tap could not be made although Input Monitoring is granted.
    public static let hint = "fn not received: re-grant Input Monitoring"
    /// 🌐 reached the tap but fn did not: Input Monitoring works, something ahead of Shepetal took fn.
    public static let taken = "fn not received: another app may be taking it"

    private var fnDown = false
    private var lastFn: TimeInterval = -.infinity
    private var globe: TimeInterval?  // a 179 keyDown no fn event has matched yet

    public init() {}

    /// The tap saw keycode 63 at `t`: fn went down or up.
    public mutating func fn(down: Bool, at t: TimeInterval) {
        fnDown = down
        lastFn = t
        if let g = globe, t - g <= Self.window { globe = nil }
    }

    /// The tap saw keycode 179 go down at `t`.
    public mutating func globe(at t: TimeInterval) {
        guard globe == nil, !fnDown, t - lastFn > Self.window else { return }
        globe = t
    }

    /// True once per 🌐 press that no fn event came with, once `window` has passed.
    public mutating func poll(at t: TimeInterval) -> Bool {
        guard let g = globe, t - g >= Self.window else { return false }
        globe = nil
        return true
    }
}
