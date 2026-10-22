import Foundation

/// F18: a dictation whose speech-to-text and cleanup are still running after a few seconds says so once, next to
/// 🤫. Only this local notice exists: a dictation makes no network call (rule 5), so there is no degraded-network
/// one. `defaults write io.backant.shepetal slowNoticeSeconds 10` moves the threshold; 0 turns the notice off.
public enum SlowNotice {
    public static let key = "slowNoticeSeconds"
    public static let defaultSeconds: TimeInterval = 3
    public static let hint = "Still transcribing · long recordings take a moment"

    public static func seconds(_ defaults: UserDefaults = .standard) -> TimeInterval {
        defaults.object(forKey: key) == nil ? defaultSeconds : defaults.double(forKey: key)
    }
}

/// Runs `fire` once on the main actor after `seconds`, unless `stop()` came first. 0 or less never fires.
public final class SlowWatch: Sendable {
    private let timer: Task<Void, Never>?

    public init(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        timer = seconds > 0 ? Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if !Task.isCancelled { fire() }  // a stop() on the main actor while it woke up still wins
        } : nil
    }

    /// Safe from any thread, and more than once.
    public func stop() { timer?.cancel() }
}
