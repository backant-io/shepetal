import Foundation

/// The keyboard <-> app dictation handoff. Both processes load it from the App Group,
/// apply one transition and save it back. Every transition names the session it is for,
/// so a result from an older session can never be inserted into a newer one.
public struct Handoff: Codable, Equatable {
    public enum Phase: String, Codable { case idle, requested, recording, transcribing, ready, inserted }

    /// How long `requested`, `transcribing` and `ready` may sit untouched before the session expires.
    /// `recording` has no limit: the user decides when to stop.
    public static let timeout: TimeInterval = 60

    public private(set) var phase: Phase = .idle
    public private(set) var sessionID: UUID?
    public private(set) var text: String?
    public private(set) var updatedAt: Date = .distantPast

    public init() {}

    /// Keyboard: start a new session. Always allowed; it supersedes whatever was there.
    public mutating func request(_ id: UUID, now: Date = Date()) {
        self = Handoff()
        phase = .requested
        sessionID = id
        updatedAt = now
    }

    /// App: the microphone is live for this session.
    @discardableResult
    public mutating func startRecording(_ id: UUID, now: Date = Date()) -> Bool {
        advance(id, from: .requested, to: .recording, now: now)
    }

    /// App: the user stopped; transcription is running.
    @discardableResult
    public mutating func finishRecording(_ id: UUID, now: Date = Date()) -> Bool {
        advance(id, from: .recording, to: .transcribing, now: now)
    }

    /// App: transcription finished.
    @discardableResult
    public mutating func deliver(_ id: UUID, text: String, now: Date = Date()) -> Bool {
        guard advance(id, from: .transcribing, to: .ready, now: now) else { return false }
        self.text = text
        return true
    }

    /// Keyboard: take the text for the session it requested. Returns nil for a stale,
    /// expired or already inserted result, so the same text is never inserted twice.
    public mutating func consume(_ id: UUID, now: Date = Date()) -> String? {
        let result = text
        guard advance(id, from: .ready, to: .inserted, now: now) else { return nil }
        text = nil
        return result
    }

    public func isExpired(now: Date = Date()) -> Bool {
        switch phase {
        case .requested, .transcribing, .ready: return now.timeIntervalSince(updatedAt) > Self.timeout
        case .idle, .recording, .inserted: return false
        }
    }

    private mutating func advance(_ id: UUID, from: Phase, to: Phase, now: Date) -> Bool {
        if isExpired(now: now) { self = Handoff(); return false }
        guard sessionID == id, phase == from else { return false }
        phase = to
        updatedAt = now
        return true
    }
}

/// Shared App Group storage plus Darwin notifications between the app and the keyboard.
public enum SharedHandoff {
    public static let appGroup = "group.io.backant.shepetal"
    public static let stopNotification = "io.backant.shepetal.stop"
    public static let readyNotification = "io.backant.shepetal.ready"
    private static let key = "handoff"

    // ponytail: read-modify-write on UserDefaults is not atomic across processes. Each phase has a
    // single writer (keyboard or app), so it holds; switch to a file lock if both ever write at once.
    @discardableResult
    public static func update<T>(_ body: (inout Handoff) -> T) -> T {
        let defaults = UserDefaults(suiteName: appGroup)
        var handoff = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Handoff.self, from: $0) } ?? Handoff()
        let result = body(&handoff)
        defaults?.set(try? JSONEncoder().encode(handoff), forKey: key)
        return result
    }

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Calls `handler` on the main queue whenever `name` is posted by the other process.
    public static func observe(_ name: String, _ handler: @escaping () -> Void) {
        observers[name] = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, cfName, _, _ in
            guard let name = cfName?.rawValue as String? else { return }
            DispatchQueue.main.async { SharedHandoff.observers[name]?() }
        }, name as CFString, nil, .deliverImmediately)
    }

    private static var observers: [String: () -> Void] = [:]
}
