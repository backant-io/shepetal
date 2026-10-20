import Foundation

/// The keyboard <-> app dictation handoff. Both processes load it from the App Group,
/// apply one transition and save it back. Every transition names the session it is for,
/// so a result from an older session can never be inserted into a newer one.
public struct Handoff: Codable, Equatable {
    public enum Phase: String, Codable { case idle, requested, recording, transcribing, ready, inserted, cancelled }

    /// How long `requested`, `transcribing` and `ready` may sit untouched before the session expires.
    public static let timeout: TimeInterval = 60
    /// One dictation is capped at 5 minutes (same as Wispr). The app stops itself at the cap; a recording
    /// still open `timeout` after the cap means the app died, and the session expires.
    public static let maxRecording: TimeInterval = 5 * 60

    public private(set) var phase: Phase = .idle
    public private(set) var sessionID: UUID?
    /// `textDocumentProxy.documentIdentifier` of the field the dictation was started in.
    public private(set) var documentID: UUID?
    public private(set) var text: String?
    public private(set) var updatedAt: Date = .distantPast

    public init() {}

    /// Keyboard: start a new session from the field `document`. Always allowed; it supersedes whatever was there.
    public mutating func request(_ id: UUID, document: UUID, now: Date = Date()) {
        self = Handoff()
        phase = .requested
        sessionID = id
        documentID = document
        updatedAt = now
    }

    /// App: true only for a pending, unexpired request with this id. Check it before touching the mic.
    public func canStart(_ id: UUID, now: Date = Date()) -> Bool {
        phase == .requested && sessionID == id && !isExpired(now: now)
    }

    /// App: claim the request, then start the mic. `startMic` runs only for a valid request,
    /// and if it throws the session is rolled back to idle.
    @discardableResult
    public mutating func startRecording(_ id: UUID, now: Date = Date(), startMic: () throws -> Void) -> Bool {
        guard advance(id, from: .requested, to: .recording, now: now) else { return false }
        do {
            try startMic()
            return true
        } catch {
            self = Handoff()
            return false
        }
    }

    /// App: keep the mic on only while this is true. False once the session is superseded,
    /// cancelled or expired, or has reached `maxRecording`.
    public func shouldKeepRecording(_ id: UUID, now: Date = Date()) -> Bool {
        phase == .recording && sessionID == id && now.timeIntervalSince(updatedAt) < Self.maxRecording
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

    /// Keyboard: take the text for the session it requested, in the field it is showing now.
    /// Returns nil for a stale, expired or already inserted result, so the same text is never
    /// inserted twice. A ready result shown in a different field is discarded, never inserted.
    public mutating func consume(_ id: UUID, document: UUID, now: Date = Date()) -> String? {
        let result = text
        guard advance(id, from: .ready, to: .inserted, now: now) else { return nil }
        text = nil
        guard document == documentID else {
            self = Handoff()
            return nil
        }
        return result
    }

    /// Either side: give up on the session. Only the session id is needed; the app keeps the audio.
    @discardableResult
    public mutating func cancel(_ id: UUID, now: Date = Date()) -> Bool {
        guard sessionID == id, [.requested, .recording, .transcribing, .ready].contains(phase) else { return false }
        phase = .cancelled
        text = nil
        updatedAt = now
        return true
    }

    public func isExpired(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        switch phase {
        case .requested, .transcribing, .ready: return age > Self.timeout
        case .recording: return age > Self.maxRecording + Self.timeout
        case .idle, .inserted, .cancelled: return false
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

/// Raw audio of every dictation, kept in the app's own Application Support/audio/ (never the
/// App Group, so the keyboard cannot read it). Files are only ever written, never deleted.
public enum AudioArchive {
    public static let sampleRate = 16_000

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("audio", isDirectory: true)
    }

    public static func url(for id: UUID, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    /// Writes the exact samples as a 32-bit float mono WAV, readable only while the device is unlocked.
    @discardableResult
    public static func save(_ samples: [Float], id: UUID, in directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(for: id, in: directory)
        try wav(samples).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Cancels the session. The audio is saved like any other dictation and stays on disk.
    public static func cancel(_ id: UUID, samples: [Float], handoff: inout Handoff, in directory: URL = directory) throws {
        try save(samples, id: id, in: directory)
        handoff.cancel(id)
    }

    static func wav(_ samples: [Float]) -> Data {
        let dataSize = UInt32(samples.count * 4)
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16))
        put(UInt16(3)) // IEEE float
        put(UInt16(1)) // mono
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 4)); put(UInt16(4)); put(UInt16(32))
        data.append(contentsOf: Array("data".utf8)); put(dataSize)
        samples.forEach { put($0.bitPattern) }
        return data
    }
}

/// Shared App Group storage plus Darwin notifications between the app and the keyboard.
public enum SharedHandoff {
    public static let appGroup = "group.io.backant.shepetal"
    public static let stopNotification = "io.backant.shepetal.stop"
    public static let readyNotification = "io.backant.shepetal.ready"
    private static let key = "handoff"

    public static func read() -> Handoff { update { $0 } }

    // ponytail: read-modify-write on UserDefaults is not atomic across processes. Each phase has a
    // single writer (keyboard or app), so it holds; switch to a file lock if both ever write at once.
    @discardableResult
    public static func update<T>(_ body: (inout Handoff) throws -> T) rethrows -> T {
        let defaults = UserDefaults(suiteName: appGroup)
        var handoff = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Handoff.self, from: $0) } ?? Handoff()
        let result = try body(&handoff)
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
