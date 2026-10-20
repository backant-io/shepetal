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

/// Detector to recorder: the probe runs every second, a detected meeting is recorded until the detector
/// says it ended, then the meeting goes to `onEnded` (the transcriber). The menu item starts and stops by hand.
@MainActor
final class MeetingRecorder: NSObject {
    nonisolated static let manualApp = "Manual"

    private(set) var detector: MeetingDetector
    private let dir: URL
    private let capture: MeetingCapturing
    private let hint: (String) -> Void
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
         detector: MeetingDetector = MeetingRecorder.configuredDetector(), hint: @escaping (String) -> Void) {
        self.dir = dir
        self.capture = capture
        self.detector = detector
        self.hint = hint
    }

    /// The detector thresholds from docs/re/meetings.md, each overridable with
    /// `defaults write io.backant.shepetal meeting.<name> <seconds>`.
    nonisolated static func configuredDetector(_ defaults: UserDefaults = .standard) -> MeetingDetector {
        var d = MeetingDetector()
        let keys: [(String, WritableKeyPath<MeetingDetector, Double>)] = [
            ("startAfter", \.startAfter), ("holdoff", \.holdoff), ("minSession", \.minSession),
            ("endWithEvidence", \.endWithEvidence), ("endWithoutEvidence", \.endWithoutEvidence),
            ("reacquire", \.reacquire), ("deviceChangeGrace", \.deviceChangeGrace),
        ]
        for (name, path) in keys {
            if let v = defaults.object(forKey: "meeting.\(name)") as? Double { d[keyPath: path] = v }
        }
        return d
    }

    /// Polls `probe` off the main thread every second (window titles and EventKit can be slow) and
    /// feeds the detector on the main thread.
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

    /// One detector step. A stopped-by-hand meeting stays active in the detector, so it is not restarted
    /// until it ends and a new one starts.
    func update(_ snapshot: Snapshot, now: Double) {
        for event in detector.update(snapshot, now: now) {
            switch event {
            case .started(let app) where current == nil: start(app: app)
            case .ended(let app) where current?.app == app: stop()
            default: break
            }
        }
    }

    func start(app: String = MeetingRecorder.manualApp) {
        guard current == nil else { return }
        let id = Self.newID()
        let folder = dir.appendingPathComponent(id)
        do {
            try AudioStore.makeOwnerOnlyDirectory(folder)  // rule 4: 0700, the capture writes 0600 files
            let both = try capture.start(dir: folder)
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

    func stop() {
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
        hint(problem.map { "Meeting saved, but: \($0)" } ?? "Meeting recording saved")
        onEnded(meeting)
    }

    var menuItem: NSMenuItem {
        let i = NSMenuItem(title: current == nil ? "Start meeting recording" : "Stop meeting recording",
                           action: #selector(toggle), keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func toggle() { if current == nil { start() } else { stop() } }

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
    private var file: AVAudioFile?

    func start(_ url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError("No microphone") }
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
                               interleaved: format.isInterleaved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.withLock { try? self.file?.write(from: buf) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Releasing the file finalises the WAV header before the meeting is handed over.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { file = nil }
    }
}
