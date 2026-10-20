import Foundation
import UIKit
import UniformTypeIdentifiers

/// The keyboard <-> app dictation handoff. Both processes load it from the App Group,
/// apply one transition and save it back. Every transition names the session it is for,
/// so a result from an older session can never be inserted into a newer one.
public struct Handoff: Codable, Equatable {
    public enum Phase: String, Codable { case idle, requested, recording, transcribing, ready, inserted, cancelled, failed }

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
    /// Shown by the keyboard: why the session failed, or a note on delivered text (for example a recording cut short).
    public private(set) var message: String?
    /// Set by the keyboard when the user taps the mic to finish. The stop notification only wakes the app;
    /// the app stops only when this is set for its own recording.
    public private(set) var stopRequested = false
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
    /// and if it throws the session fails with a message for the keyboard.
    @discardableResult
    public mutating func startRecording(_ id: UUID, now: Date = Date(), startMic: () throws -> Void) -> Bool {
        guard advance(id, from: .requested, to: .recording, now: now) else { return false }
        do {
            try startMic()
            return true
        } catch {
            fail(id, "Could not start the microphone: \(error.localizedDescription)", now: now)
            return false
        }
    }

    /// App: keep the mic on only while this is true. False once the session is superseded,
    /// cancelled or expired, or has reached `maxRecording`.
    public func shouldKeepRecording(_ id: UUID, now: Date = Date()) -> Bool {
        phase == .recording && sessionID == id && now.timeIntervalSince(updatedAt) < Self.maxRecording
    }

    /// Keyboard: ask the app to finish the recording `id`, before posting the stop notification.
    /// False when `id` is not recording, so the keyboard starts a new dictation instead.
    @discardableResult
    public mutating func requestStop(_ id: UUID, now: Date = Date()) -> Bool {
        guard phase == .recording, sessionID == id, !isExpired(now: now) else { return false }
        stopRequested = true
        return true
    }

    /// App: the user stopped; transcription is running.
    @discardableResult
    public mutating func finishRecording(_ id: UUID, now: Date = Date()) -> Bool {
        advance(id, from: .recording, to: .transcribing, now: now)
    }

    /// App: transcription finished. `note` is shown by the keyboard after it inserts the text.
    @discardableResult
    public mutating func deliver(_ id: UUID, text: String, note: String? = nil, now: Date = Date()) -> Bool {
        guard advance(id, from: .transcribing, to: .ready, now: now) else { return false }
        self.text = text
        message = note
        return true
    }

    /// What the keyboard does with a ready result.
    public enum Delivery: Equatable {
        /// Insert into the field the dictation started in.
        case insert(String)
        /// Goal rule 8: the user is in a different field now, so the text goes to the clipboard as plain text
        /// (the old clipboard is not restored) and the hint says to paste.
        case copy(String)
    }

    /// Keyboard: take the text for the session it requested, in the field it is showing now.
    /// Returns nil for a stale, expired or already delivered result, so the same text is never
    /// delivered twice. A ready result shown in a different field is never inserted there: it is copied
    /// instead (goal rule 8), and the paste hint goes before any note delivered with the text.
    public mutating func consume(_ id: UUID, document: UUID, now: Date = Date()) -> Delivery? {
        let result = text
        guard advance(id, from: .ready, to: .inserted, now: now), let result else { return nil }
        text = nil
        if document == documentID { return .insert(result) }
        message = [Self.copiedHint, message].compactMap { $0 }.joined(separator: " ")
        return .copy(result)
    }

    static let copiedHint = "You are in a different field now, so the text is on the clipboard. Tap the field and choose Paste."

    /// Keyboard: the clipboard write for a `.copy` did not land, so the paste hint would be wrong.
    /// The session fails and says where the text is instead.
    @discardableResult
    public mutating func copyFailed(_ id: UUID, now: Date = Date()) -> Bool {
        guard sessionID == id, phase == .inserted else { return false }
        phase = .failed
        message = "Not inserted, because you are in a different field now. The text is in Shepetal's history."
        updatedAt = now
        return true
    }

    /// Either side: give up on the session. Only the session id is needed; the app keeps the audio.
    @discardableResult
    public mutating func cancel(_ id: UUID, now: Date = Date()) -> Bool {
        end(id, as: .cancelled, message: nil, now: now)
    }

    /// App: the session ended without text (no model, too short, transcription error). The keyboard shows `message`.
    @discardableResult
    public mutating func fail(_ id: UUID, _ message: String, now: Date = Date()) -> Bool {
        end(id, as: .failed, message: message, now: now)
    }

    /// Keyboard: the text shown next to 🤫 for the keyboard's own session `id`. Says why a dictation
    /// did not end in inserted text, so no failure is silent. Nil when there is nothing to say.
    public func keyboardStatus(for id: UUID?, now: Date = Date()) -> String? {
        guard let id else { return nil }
        guard sessionID == id, !isExpired(now: now) else {
            return "That dictation timed out. If it was transcribed, the text is in Shepetal's history."
        }
        switch phase {
        case .requested: return "Opening Shepetal..."
        case .recording: return "Listening. Tap the mic to finish."
        case .transcribing: return "Transcribing..."
        case .ready, .idle: return nil
        case .inserted, .failed: return message
        case .cancelled: return "Cancelled. Shepetal kept the audio."
        }
    }

    /// Keyboard: the ring color of 🤫 for the keyboard's own session `id`, matching `keyboardStatus`.
    public func indicatorMode(for id: UUID?, now: Date = Date()) -> Indicator.Mode {
        guard let id else { return .idle }
        guard sessionID == id, !isExpired(now: now) else { return .error }
        switch phase {
        case .recording: return .recording
        case .requested, .transcribing, .ready: return .processing
        case .failed: return .error
        case .idle, .inserted, .cancelled: return .idle
        }
    }

    public func isExpired(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        switch phase {
        case .requested, .transcribing, .ready: return age > Self.timeout
        case .recording: return age > Self.maxRecording + Self.timeout
        case .idle, .inserted, .cancelled, .failed: return false
        }
    }

    private mutating func end(_ id: UUID, as end: Phase, message: String?, now: Date) -> Bool {
        guard sessionID == id, [.requested, .recording, .transcribing, .ready].contains(phase) else { return false }
        phase = end
        text = nil
        self.message = message
        updatedAt = now
        return true
    }

    private mutating func advance(_ id: UUID, from: Phase, to: Phase, now: Date) -> Bool {
        if isExpired(now: now) { self = Handoff(); return false }
        guard sessionID == id, phase == from else { return false }
        phase = to
        updatedAt = now
        return true
    }
}

/// One kept recording: the history entry `<id>.json`, saved next to its audio `<id>.wav`.
public struct Recording: Codable, Equatable, Identifiable {
    public enum Outcome: String, Codable { case recorded, transcribed, cancelled, tooShort, failed }
    public let id: UUID
    public let date: Date
    public var outcome: Outcome
    public var text: String?
    public var note: String?
    /// File name of the raw audio, in the same directory.
    public let audio: String

    public init(id: UUID, date: Date, outcome: Outcome, text: String? = nil, note: String? = nil) {
        self.id = id
        self.date = date
        self.outcome = outcome
        self.text = text
        self.note = note
        audio = "\(id.uuidString).wav"
    }
}

/// Raw audio and history of every dictation, kept in the app's own Application Support/audio/
/// (never the App Group, so the keyboard cannot read it), excluded from iCloud and device backup.
/// Files are deleted only by `sweep`, when the user chose "delete after 24 h".
public enum AudioArchive {
    public static let sampleRate = 16_000

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("audio", isDirectory: true)
    }

    public static func url(for id: UUID, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    /// Writes the exact samples as a 32-bit float mono WAV, readable only while the device is unlocked.
    /// Fails while the device is locked; the caller keeps the samples and retries.
    @discardableResult
    public static func save(_ samples: [Float], id: UUID, in directory: URL = directory) throws -> URL {
        try prepare(directory)
        let url = url(for: id, in: directory)
        try wav(samples).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Writes the history entry next to its audio.
    public static func write(_ entry: Recording, in directory: URL = directory) throws {
        try prepare(directory)
        try JSONEncoder().encode(entry).write(to: entryURL(for: entry.id, in: directory), options: [.atomic, .completeFileProtection])
    }

    /// Every kept recording, newest first.
    public static func history(in directory: URL = directory) -> [Recording] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Recording.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    /// Deletes the audio and entry of every recording older than `age`. Returns the deleted ids.
    /// The entry goes only after its audio is gone, so a failed delete is retried on the next sweep.
    @discardableResult
    public static func sweep(olderThan age: TimeInterval, now: Date = Date(), in directory: URL = directory) -> [UUID] {
        history(in: directory).filter { now.timeIntervalSince($0.date) > age }.compactMap { entry in
            let audio = url(for: entry.id, in: directory)
            do {
                if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
                try FileManager.default.removeItem(at: entryURL(for: entry.id, in: directory))
                return entry.id
            } catch {
                return nil
            }
        }
    }

    static func entryURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Application Support is included in iCloud and device backups unless excluded. The audio never leaves the device.
    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
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

/// Goal rule 8 on iPhone: a result for a different field is left on the clipboard.
public enum Clipboard {
    /// Replaces the clipboard with `text` as plain text. Local only: it is not sent to the user's other
    /// devices by Universal Clipboard. Tests pass a private named pasteboard, never `.general`.
    /// Returns false when the write did not land (the change count did not move or the text differs).
    @discardableResult
    public static func copy(_ text: String, to pasteboard: UIPasteboard = .general) -> Bool {
        let before = pasteboard.changeCount
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        return pasteboard.changeCount != before && pasteboard.string == text
    }
}

/// Shared App Group storage plus Darwin notifications between the app and the keyboard.
public enum SharedHandoff {
    public static let appGroup = "group.io.backant.shepetal"
    public static let stopNotification = "io.backant.shepetal.stop"
    /// Posted by the keyboard after writing a request, instead of opening the app, while the app is listening.
    public static let startNotification = "io.backant.shepetal.start"
    /// The app's heartbeat is this recent while its mic is open (it writes one every second).
    public static let listeningWindow: TimeInterval = 3
    /// Posted by the app whenever the keyboard's session moves on: ready, failed or cancelled.
    public static let readyNotification = "io.backant.shepetal.ready"
    public static let shared = UserDefaults(suiteName: appGroup)
    private static let key = "handoff"

    public static func read(in defaults: UserDefaults? = shared) -> Handoff { update(in: defaults) { $0 } }

    // ponytail: read-modify-write on UserDefaults is not atomic across processes. Each phase has a
    // single writer (keyboard or app), except `recording`, where the keyboard's stop request can race the
    // app ending the recording itself (cap, dead mic); switch to a file lock if that race shows up.
    @discardableResult
    public static func update<T>(in defaults: UserDefaults? = shared, _ body: (inout Handoff) throws -> T) rethrows -> T {
        var handoff = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Handoff.self, from: $0) } ?? Handoff()
        let result = try body(&handoff)
        defaults?.set(try? JSONEncoder().encode(handoff), forKey: key)
        return result
    }

    /// App: its mic is open and it starts dictations from the keyboard's start notification. Nil when it closes the mic.
    /// Kept apart from the handoff, so the heartbeat never races the keyboard's writes.
    public static func markListening(_ now: Date?, in defaults: UserDefaults? = shared) {
        defaults?.set(now, forKey: listeningKey)
    }

    /// Keyboard: true when the app wrote a heartbeat within `listeningWindow`, so a dictation can start
    /// without opening the app. A heartbeat from the future (clock change) does not count.
    public static func isAppListening(now: Date = Date(), in defaults: UserDefaults? = shared) -> Bool {
        guard let beat = defaults?.object(forKey: listeningKey) as? Date else { return false }
        let age = now.timeIntervalSince(beat)
        return age >= -1 && age < listeningWindow
    }

    private static let listeningKey = "appListeningAt"

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
