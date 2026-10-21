import AppKit
import AVFoundation
import MeetingCore
import MeetingMac
import ShepetalCore

/// Records a meeting into `dir`/Me.wav (mic) and `dir`/Others.wav (system audio).
/// The app uses `SystemMeetingCapture`; tests use a fake, so they never need TCC.
protocol MeetingCapturing: AnyObject {
    /// Returns false when only the mic ("Me") is recorded because system audio is not allowed.
    func start(dir: URL) throws -> Bool
    func stop() throws
}

/// Pavel's decision (1): a detected meeting is only offered, on a card next to 🤫. Capture starts on one click on
/// Record, or at once when "Always record meetings automatically" is on (off by default). Not now, the 20 s
/// timeout and the meeting ending first record nothing for that meeting. Pure, so tests drive the clock.
struct MeetingOffer {
    enum Step: Equatable { case none, offer(String), record(String), dismiss }
    static let seconds: Double = 20

    /// The app on the card; nil while no card shows.
    private(set) var app: String?
    private var until = 0.0

    mutating func detected(_ app: String, autoRecord: Bool, now: Double) -> Step {
        guard !autoRecord else { self.app = nil; return .record(app) }
        self.app = app
        until = now + Self.seconds
        return .offer(app)
    }

    /// The card's Record button: the one click that starts capture.
    mutating func record() -> Step {
        guard let app else { return .none }
        self.app = nil
        return .record(app)
    }

    mutating func notNow() -> Step { dismiss(if: app != nil) }
    mutating func tick(now: Double) -> Step { dismiss(if: app != nil && now >= until) }
    /// The offered meeting ended before anyone clicked.
    mutating func ended(_ app: String) -> Step { dismiss(if: app == self.app) }

    private mutating func dismiss(if yes: Bool) -> Step {
        guard yes else { return .none }
        app = nil
        return .dismiss
    }
}

/// F67: a recording nobody speaks in ends by itself, detected or started by hand, so a forgotten one does not run
/// forever. It is clocked in recorded audio, per channel, and ends once every channel has been quiet for `seconds`
/// (`defaults write io.backant.shepetal meeting.silenceEnd <seconds>`, 0 turns it off), never in the first
/// `minSession`. Pure, so tests feed it blocks of audio.
/// ponytail: speech is a block the model heard words in, and a block with speech resets its channel's clock, so the
/// end can come one block (30 s live) late; a line still running at a block's end counts only once it ends, so a
/// line started just before the end and never paused for 0.5 s can be cut off; and no model loaded means no
/// clock. Count the quiet tail of the block, or ask Utterances whether one is open, if either matters.
struct SilenceEnd {
    static let key = "meeting.silenceEnd"
    static let defaultSeconds = 120.0

    /// The quiet that ends a recording: `seconds`, but never less than `minSession`.
    let after: Double
    let on: Bool
    /// Recorded seconds since each channel of the recording last had speech. A channel not read yet holds the end.
    private var quiet: [Speaker: Double] = [:]

    init(seconds: Double, minSession: Double) {
        on = seconds > 0
        after = max(seconds, minSession)
    }

    /// A block of newly recorded audio on one channel. True once the recording should end.
    mutating func heard(_ speaker: Speaker, seconds: Double, speech: Bool) -> Bool {
        guard let q = quiet[speaker] else { return false }
        quiet[speaker] = speech ? 0 : q + seconds
        return on && quiet.values.allSatisfy { $0 >= after }
    }

    /// A new recording of these channels.
    mutating func start(_ channels: [Speaker]) { quiet = Dictionary(uniqueKeysWithValues: channels.map { ($0, 0.0) }) }

    /// "2 min", "40 s".
    var said: String {
        after >= 60 && after.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(after / 60)) min" : "\(Int(after)) s"
    }
}

/// Detector to recorder: the probe runs every second, a detected meeting is offered (`MeetingOffer`) and, once
/// accepted, recorded until the detector says it ended, then the meeting goes to `onEnded` (the transcriber).
/// The menu item starts and stops by hand.
@MainActor
final class MeetingRecorder: NSObject {
    nonisolated static let manualApp = "Manual"
    /// "Always record meetings automatically" in Settings; unset means off.
    nonisolated static let autoRecordKey = "meeting.autoRecord"

    private(set) var detector: MeetingDetector
    let dir: URL
    private let capture: MeetingCapturing
    private let hint: (String) -> Void
    private let autoRecord: () -> Bool
    /// Shows the "Meeting detected · <app>" card, or hides it for nil.
    private let card: (String?) -> Void
    private var offer = MeetingOffer()
    private var silence: SilenceEnd
    private var timer: DispatchSourceTimer?
    /// The meeting being recorded; nil when idle.
    private(set) var current: Meeting?
    /// Gets each finished meeting with the channels that were written ("" for a missing one).
    var onEnded: (Meeting) -> Void = { _ in }
    /// Gets each meeting as its recording starts, so it is stored and transcribed while it runs.
    var onStarted: (Meeting) -> Void = { _ in }
    /// Gets a meeting that ended with no audio written; it is not kept.
    var onDiscarded: (Meeting) -> Void = { _ in }

    init(dir: URL = Paths.root.appendingPathComponent("meetings"), capture: MeetingCapturing,
         detector: MeetingDetector = MeetingRecorder.configuredDetector(),
         autoRecord: @escaping () -> Bool = { MeetingRecorder.autoRecords() },
         silenceEnd: Double = MeetingRecorder.configuredSilenceEnd(),
         card: @escaping (String?) -> Void, hint: @escaping (String) -> Void) {
        self.dir = dir
        self.capture = capture
        self.detector = detector
        silence = SilenceEnd(seconds: silenceEnd, minSession: detector.minSession)
        self.autoRecord = autoRecord
        self.card = card
        self.hint = hint
    }

    nonisolated static func autoRecords(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: autoRecordKey) }

    /// The detector for this process (its own mic use never counts), with the thresholds from docs/re/meetings.md,
    /// each overridable with `defaults write io.backant.shepetal meeting.<name> <seconds>`.
    nonisolated static func configuredDetector(_ defaults: UserDefaults = .standard) -> MeetingDetector {
        var d = MeetingDetector(ownPID: ProcessInfo.processInfo.processIdentifier, ownBundleID: Bundle.main.bundleIdentifier)
        let keys: [(String, WritableKeyPath<MeetingDetector, Double>)] = [
            ("startAfter", \.startAfter), ("holdoff", \.holdoff), ("minSession", \.minSession),
            ("endAfter", \.endAfter), ("deviceChangeGrace", \.deviceChangeGrace),
        ]
        for (name, path) in keys {
            if let v = defaults.object(forKey: "meeting.\(name)") as? Double { d[keyPath: path] = v }
        }
        return d
    }

    /// `meeting.silenceEnd` in seconds; unset means 120. `defaults write` without a type stores "40" as text, which
    /// counts too.
    nonisolated static func configuredSilenceEnd(_ defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: SilenceEnd.key) == nil ? SilenceEnd.defaultSeconds : defaults.double(forKey: SilenceEnd.key)
    }

    /// Polls `probe` (which apps use the mic, whether a camera runs) off the main thread every second and feeds the
    /// detector on the main thread.
    func watch(probe: @escaping @Sendable () -> Snapshot = { Probes.snapshot() }) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.backant.shepetal.meeting-probe"))
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in
            let snapshot = probe()
            let now = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(snapshot, now: now) } }
        }
        t.resume()
        timer = t
    }

    /// One detector step, which also times the card out. A declined or stopped-by-hand meeting stays active in
    /// the detector, so it is not offered again until it ends and a new one starts.
    func update(_ snapshot: Snapshot, now: Double) {
        for event in detector.update(snapshot, now: now) {
            switch event {
            case .started(let app) where current == nil: apply(offer.detected(app, autoRecord: autoRecord(), now: now))
            case .ended(let app):
                if current?.app == app { stop() }
                apply(offer.ended(app))
            default: break
            }
        }
        apply(offer.tick(now: now))
    }

    /// The card's buttons.
    func record() { apply(offer.record()) }
    func notNow() { apply(offer.notNow()) }

    private func apply(_ step: MeetingOffer.Step) {
        switch step {
        case .none: break
        case .offer(let app): card(app)
        case .dismiss: card(nil)
        case .record(let app):
            card(nil)
            start(app: app)
        }
    }

    func start(app: String = MeetingRecorder.manualApp) {
        guard current == nil else { return }
        let id = Self.newID()
        let folder = dir.appendingPathComponent(id)
        do {
            try AudioStore.makeOwnerOnlyDirectory(folder)  // rule 4: 0700, the capture writes 0600 files
            let both = try capture.start(dir: folder)
            silence.start(both ? [.me, .others] : [.me])
            current = Meeting(id: id, app: app, startedAt: Date(),
                              meAudioPath: folder.appendingPathComponent("Me.wav").path,
                              othersAudioPath: both ? folder.appendingPathComponent("Others.wav").path : "")
            let what = app == Self.manualApp ? "Recording meeting" : "Meeting detected · recording"
            hint(both ? what : "\(what) mic only (turn on System Audio Recording)")
            current.map(onStarted)
        } catch {
            hint("Meeting recording failed: \(error.localizedDescription)")
        }
    }

    /// A block of newly recorded audio from the live transcriber. Only the meeting recording now counts, not the
    /// last pass of one that already ended.
    func heard(_ id: String, _ speaker: Speaker, seconds: Double, speech: Bool) {
        guard current?.id == id, silence.heard(speaker, seconds: seconds, speech: speech) else { return }
        stop(saved: "Meeting ended · no one spoke for \(silence.said)")
    }

    /// `saved` is the hint when the audio was kept.
    func stop(saved: String = "Meeting recording saved") {
        guard var meeting = current else { return }
        current = nil
        var problem: String?
        do { try capture.stop() } catch { problem = error.localizedDescription }
        meeting.endedAt = Date()
        for path in [\Meeting.meAudioPath, \.othersAudioPath] where !FileManager.default.fileExists(atPath: meeting[keyPath: path]) {
            meeting[keyPath: path] = ""
        }
        guard !meeting.meAudioPath.isEmpty || !meeting.othersAudioPath.isEmpty else {
            onDiscarded(meeting)
            return hint("Meeting not saved: \(problem ?? "no audio was captured")")
        }
        hint(problem.map { "Meeting saved, but: \($0)" } ?? saved)
        onEnded(meeting)
    }

    /// The 🤫 menu's Record meeting / Stop meeting recording.
    func toggle() {
        guard current == nil else { return stop() }
        apply(offer.notNow())  // recording by hand answers the card too
        start()
    }

    private static func newID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased())"
    }
}

/// The real capture: mic plus a Core Audio process tap (meeting/), or the mic alone when the
/// System Audio Recording permission is missing or the tap cannot start. Hand-tested only.
final class SystemMeetingCapture: MeetingCapturing {
    private let allowPrompts: Bool
    private var both: MeetingCapture?
    private var micOnly: MicFile?

    init(allowPrompts: Bool) { self.allowPrompts = allowPrompts }

    func start(dir: URL) throws -> Bool {
        guard Recorder.micAllowed else { throw SpeechError("Microphone access is off") }
        let status = Self.systemAudioStatus()
        if status == 0 || (allowPrompts && status != 1) {  // granted, or not asked yet and we may ask
            let c = MeetingCapture()
            do {
                try c.start(dir: dir)
                both = c
                return true
            } catch {
                try? c.stop()  // releases what start made
                NSLog("shepetal: system audio tap failed, recording the mic only: \(error)")
            }
        }
        let m = MicFile()
        try m.start(dir.appendingPathComponent("Me.wav"))
        micOnly = m
        return false
    }

    func stop() throws {
        defer { both = nil; micOnly = nil }
        micOnly?.stop()
        do { try both?.stop() } catch { throw SpeechError("\(error)") }
    }

    /// TCC's read-only check for System Audio Recording; there is no public API and it never prompts.
    /// 0 granted, 1 denied, 2 not asked yet, nil when the symbol is missing.
    static func systemAudioStatus() -> Int? {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        return unsafeBitCast(sym, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil)
    }
}

/// The default input as it comes, into one owner-only WAV.
final class MicFile {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: WavWriter?

    func start(_ url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError("No microphone") }
        guard format.commonFormat == .pcmFormatFloat32 else { throw SpeechError("Unsupported microphone format") }
        file = try WavWriter(url, rate: format.sampleRate, channels: Int(format.channelCount))  // crash-safe (#100)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.withLock { try? self.file?.append(buf) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Closes the file before the meeting is handed over; its header is already up to date.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { file = nil }
    }
}
