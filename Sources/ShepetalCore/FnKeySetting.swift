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

        public init(read: @escaping () -> Int?, write: @escaping (Int?) -> Void, restartInputAgents: @escaping () -> Void,
                    loadPrevious: @escaping () -> Int?, storePrevious: @escaping (Int?) -> Void) {
            self.read = read
            self.write = write
            self.restartInputAgents = restartInputAgents
            self.loadPrevious = loadPrevious
            self.storePrevious = storePrevious
        }
    }

    public enum Outcome: Equatable {
        /// Already Do Nothing: nothing written, nothing said.
        case alreadySet
        /// Was `from` (nil: absent), is 0 now, read back.
        case changed(from: Int?)
        /// Wrote 0 but read back something else.
        case failed(readBack: Int?)

        /// The text next to 🤫, or nil to stay silent.
        public var hint: String? {
            switch self {
            case .alreadySet: nil
            case .changed: FnKeySetting.changedHint
            case .failed: FnKeySetting.failedHint
            }
        }
    }

    /// Run at every launch (and by the installer).
    public static func apply(_ io: IO) -> Outcome {
        let current = io.read()
        guard current != doNothing else { return .alreadySet }
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

/// Notices when fn is pressed (the HID state says so) but the event tap never reports it: the
/// Input Monitoring grant is stale (for example it was given to an earlier build) or the tap is dead.
public struct FnHealth {
    public static let grace: TimeInterval = 1.0
    /// A tap event this long before the HID state showed fn down still counts for that press.
    public static let slack: TimeInterval = 0.5
    public static let hint = "fn not received: re-grant Input Monitoring"

    private var hidDownSince: TimeInterval?
    private var lastTapEvent: TimeInterval = -.infinity
    private var alerted = false

    public init() {}

    /// The tap reported fn going down or up at `t`.
    public mutating func tapEvent(at t: TimeInterval) { lastTapEvent = t }

    /// Polled HID state of fn. Returns true once per press that the tap never reported, after `grace`.
    public mutating func poll(hidFnDown: Bool, at t: TimeInterval) -> Bool {
        guard hidFnDown else {
            hidDownSince = nil
            alerted = false
            return false
        }
        let since = hidDownSince ?? t
        hidDownSince = since
        guard !alerted, t - since >= Self.grace, lastTapEvent < since - Self.slack else { return false }
        alerted = true
        return true
    }
}
