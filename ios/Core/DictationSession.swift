import Foundation

/// The app's microphone. The app uses AVAudioEngine and feeds 16 kHz mono chunks to `DictationSession.append`.
public protocol Microphone: AnyObject {
    func start() throws
    func stop()
    /// False once the system stopped the mic under us: a call, Siri, an audio interruption or a route change.
    var isRunning: Bool { get }
}

/// The app's side of a dictation, with no audio hardware or speech model in it, so tests can drive it.
/// The mic starts only for a request the keyboard wrote. Every recording keeps its raw audio and a history
/// entry, whatever happens to it. The keyboard is told how every session ends.
@MainActor
public final class DictationSession: ObservableObject {
    public static let retention: TimeInterval = 24 * 60 * 60
    /// FluidAudio rejects audio under 0.3 s.
    public static let minimumSamples = AudioArchive.sampleRate * 3 / 10
    static let ready = "Ready. Tap the mic on the Shepetal keyboard."

    @Published public private(set) var status = "Loading speech model..."
    /// Set while recordings are held in memory because they could not be written (the iPhone is locked).
    /// Later status changes never clear it; only a successful `flush()` does.
    @Published public private(set) var saveError: String?
    @Published public private(set) var history: [Recording]
    @Published public private(set) var isRecording = false
    /// Keep (the default) or delete recordings after 24 h.
    @Published public var deleteAfter24h: Bool {
        didSet { settings.set(deleteAfter24h, forKey: "deleteAfter24h"); sweep() }
    }
    /// What the Live Activity shows: recording, then processing, nil once the text is delivered or the
    /// recording is cancelled, error when it ended without text. Nil before the first dictation.
    public private(set) var activity: Indicator.Mode? {
        didSet { if activity != oldValue { onActivity(activity) } }
    }
    public var onActivity: @MainActor (Indicator.Mode?) -> Void = { _ in }
    /// Transcribes 16 kHz mono samples. Nil until the speech model is loaded.
    public private(set) var transcribe: (([Float]) async throws -> String)?

    private struct Unsaved { var entry: Recording; var samples: [Float]? }
    private struct Ended { var entry: Recording; let samples: [Float]; let forKeyboard: Bool }

    private let mic: Microphone
    private let directory: URL
    private let handoff: UserDefaults?
    private let settings: UserDefaults
    private let requestPermission: () async -> Bool
    private var sessionID: UUID?
    /// The newest request the app acted on. Only its outcome may set the status and the Live Activity, so an
    /// older recording that finishes late never ends the Live Activity of a newer one, even after it stopped.
    private var latestID: UUID?
    private var startedAt = Date()
    private var samples: [Float] = []
    private var unsaved: [UUID: Unsaved] = [:]
    private var watchdog: Timer?

    public init(mic: Microphone, directory: URL = AudioArchive.directory, handoff: UserDefaults? = SharedHandoff.shared,
                settings: UserDefaults = .standard, requestPermission: @escaping () async -> Bool) {
        self.mic = mic
        self.directory = directory
        self.handoff = handoff
        self.settings = settings
        self.requestPermission = requestPermission
        deleteAfter24h = settings.bool(forKey: "deleteAfter24h")
        history = AudioArchive.history(in: directory)
    }

    public func modelReady(_ transcribe: @escaping ([Float]) async throws -> String) {
        self.transcribe = transcribe
        if !isRecording { status = Self.ready }
    }

    public func modelFailed(_ error: Error) {
        status = "Model load failed: \(error.localizedDescription)"
    }

    /// The session id in shepetal://dictate?id=<UUID>, the URL the keyboard opens.
    public static func dictationID(in url: URL) -> UUID? {
        guard url.scheme == "shepetal", url.host == "dictate" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
    }

    /// Any app can open shepetal://dictate, so the mic starts only for a pending request the keyboard wrote, and only once.
    public func open(_ url: URL) async {
        guard let id = Self.dictationID(in: url), SharedHandoff.read(in: handoff).canStart(id) else {
            status = "Ignored a dictation request that did not come from the Shepetal keyboard."
            return
        }
        guard await requestPermission() else {
            tell { $0.fail(id, "Microphone access is off. Turn it on in Settings > Shepetal.") }
            status = "Microphone access denied. Enable it in Settings > Shepetal."
            return
        }
        // Checked again with no suspension before the claim: the same URL may have been opened twice
        // while the permission prompt was up, and the second open must not touch the first recording.
        guard SharedHandoff.read(in: handoff).canStart(id) else { return }
        let superseded = endRecording(reason: nil) // a recording still running was superseded by this request
        samples = []
        guard SharedHandoff.update(in: handoff, { $0.startRecording(id) { try mic.start() } }) else {
            mic.stop()
            SharedHandoff.post(SharedHandoff.readyNotification)
            if let superseded { await finish(superseded) }
            latestID = id
            setStatus("Could not start recording. Tap the mic again.", activity: .error, for: id)
            return
        }
        sessionID = id
        latestID = id
        startedAt = Date()
        isRecording = true
        status = "Listening. Go back to your app and tap the mic to finish."
        activity = .recording
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        if let superseded { await finish(superseded) }
    }

    /// Starts listening for the keyboard's stop notification.
    public func observeKeyboard() {
        SharedHandoff.observe(SharedHandoff.stopNotification) { [weak self] in
            Task { @MainActor in await self?.followKeyboard() }
        }
    }

    /// Any app can post a Darwin notification, so the stop notification only wakes the app. The recording
    /// ends only when the App Group, which only the keyboard and the app can write, holds a stop or cancel
    /// for this recording. Returns true when it ended the recording.
    @discardableResult
    public func followKeyboard() async -> Bool {
        guard let id = sessionID else { return false }
        let state = SharedHandoff.read(in: handoff)
        guard state.sessionID == id else { return false }
        if state.phase == .cancelled {
            cancel()
            return true
        }
        guard state.phase == .recording, state.stopRequested else { return false }
        await stop()
        return true
    }

    /// 16 kHz mono samples from the mic. Ignored when not recording.
    public func append(_ chunk: [Float]) {
        if sessionID != nil { samples += chunk }
    }

    /// Runs once a second while recording. Stops when the mic died, at the 5-minute cap, and as soon as
    /// the session was superseded or cancelled. Also catches a stop request whose notification got lost.
    public func tick(now: Date = Date()) async {
        guard let id = sessionID else { return }
        guard mic.isRunning else {
            await stop(reason: "Recording stopped early: the microphone was interrupted.")
            return
        }
        guard await !followKeyboard() else { return }
        let state = SharedHandoff.read(in: handoff)
        guard !state.shouldKeepRecording(id, now: now) else { return }
        await stop(reason: state.sessionID == id && state.phase == .recording ? "Stopped at the 5-minute limit." : nil)
    }

    /// Ends the recording, keeps its audio and transcribes it. The text goes to the keyboard if this is
    /// still the keyboard's session, and always to history. `reason` says why it ended early, if it did.
    public func stop(reason: String? = nil) async {
        guard let ended = endRecording(reason: reason) else { return }
        await finish(ended)
    }

    /// The user gave up on the recording. Its audio is kept and marked cancelled.
    public func cancel() {
        guard var entry = endRecording(reason: nil)?.entry else { return }
        entry.outcome = .cancelled
        keep(entry)
        tell { $0.cancel(entry.id) }
        setStatus("Cancelled. The recording is kept.", activity: nil, for: entry.id)
    }

    /// Transcribes an ended recording into history and tells the keyboard how it went.
    private func finish(_ ended: Ended) async {
        var entry = ended.entry
        let id = entry.id, reason = entry.note, samples = ended.samples
        func fail(_ outcome: Recording.Outcome, _ message: String) {
            entry.outcome = outcome
            entry.note = message
            keep(entry)
            if ended.forKeyboard { tell { $0.fail(id, message) } }
            setStatus(message, activity: .error, for: id)
        }
        guard samples.count >= Self.minimumSamples else {
            return fail(.tooShort, "Too short to transcribe. Tap the mic, speak, then tap it again.")
        }
        guard let transcribe else {
            return fail(.failed, "Not transcribed: the speech model is still loading. The audio is kept.")
        }
        setStatus("Transcribing...", activity: .processing, for: id)
        do {
            let text = try await transcribe(samples)
            entry.outcome = .transcribed
            entry.text = text
            keep(entry)
            if ended.forKeyboard { tell { $0.deliver(id, text: text, note: reason) } }
            setStatus(reason ?? Self.ready, activity: nil, for: id)
        } catch {
            fail(.failed, "Could not transcribe: \(error.localizedDescription). The audio is kept.")
        }
    }

    /// Writes recordings held in memory. Files with complete protection cannot be created while the
    /// iPhone is locked, so the app calls this again when protected data becomes available.
    public func flush() {
        var failure: Error?
        for (id, item) in unsaved {
            do {
                if let samples = item.samples {
                    try AudioArchive.save(samples, id: id, in: directory)
                    unsaved[id]?.samples = nil
                }
                try AudioArchive.write(item.entry, in: directory)
                unsaved[id] = nil
            } catch {
                failure = error
            }
        }
        if let failure {
            saveError = "\(unsaved.count) recording(s) not saved yet (\(failure.localizedDescription)). "
                + "They are kept in memory and saved when the iPhone is unlocked."
        } else {
            saveError = nil
            sweep()
        }
    }

    /// Deletes recordings older than 24 h when the user chose that. Runs on launch, when the app comes
    /// to the front and after every save.
    // ponytail: iOS gives no timer while the app is not running, so a file can outlive 24 h until the app
    // next runs; a BGAppRefreshTask would narrow that gap.
    public func sweep(now: Date = Date()) {
        guard deleteAfter24h else { return }
        let deleted = AudioArchive.sweep(olderThan: Self.retention, now: now, in: directory)
        history.removeAll { deleted.contains($0.id) }
    }

    private func keep(_ entry: Recording, samples: [Float]? = nil) {
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        unsaved[entry.id, default: Unsaved(entry: entry)].entry = entry
        if let samples { unsaved[entry.id]?.samples = samples }
        flush()
    }

    /// Applies a transition to the keyboard's session and rings the keyboard.
    private func tell(_ change: (inout Handoff) -> Bool) {
        SharedHandoff.update(in: handoff) { _ = change(&$0) }
        SharedHandoff.post(SharedHandoff.readyNotification)
    }

    /// A finished transcription must not overwrite the status or Live Activity of a newer recording, while that
    /// one records or after it stopped.
    private func setStatus(_ text: String, activity: Indicator.Mode?, for id: UUID) {
        guard sessionID == nil, id == latestID else { return }
        status = text
        self.activity = activity
    }

    /// Stops the mic, keeps the audio and moves the keyboard's session on. Synchronous, so nothing
    /// can run between the mic stopping and the audio being kept.
    private func endRecording(reason: String?) -> Ended? {
        guard let id = sessionID else { return nil }
        sessionID = nil
        isRecording = false
        watchdog?.invalidate()
        watchdog = nil
        mic.stop()
        let entry = Recording(id: id, date: startedAt, outcome: .recorded, note: reason)
        keep(entry, samples: samples) // every recording is kept, also when it is never transcribed
        let forKeyboard = SharedHandoff.update(in: handoff) { $0.finishRecording(id) }
        return Ended(entry: entry, samples: samples, forKeyboard: forKeyboard)
    }
}

/// Donate links every shepetal app shows.
public enum Donate {
    public static let coffee = URL(string: "https://buymeacoffee.com/sorcecoder")!
    public static let sponsors = URL(string: "https://github.com/sponsors/backant-io")!
}
