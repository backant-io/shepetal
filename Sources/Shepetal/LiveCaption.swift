import Foundation
import ShepetalCore

/// F13: while a dictation records, the last 10 s go through the speech engine about once a second and the words
/// show next to 🤫. Nothing here inserts text: on release Pipeline transcribes the whole recording as before.
/// Parakeet only: the alternative engine is too slow for a pass a second, and a partial still running delays the
/// final pass.
@MainActor
final class LiveCaption {
    private var state = LiveText()
    private var timer: Timer?
    private let recorded: () -> [Float]?
    private let engine: () -> SpeechEngine?
    private let enabled: () -> Bool
    private let show: (String) -> Void
    /// The pass in flight, for E2E to wait on.
    private(set) var pass: Task<Void, Never>?
    /// Partials shown this run.
    private(set) var shown = 0

    /// `recorded`: the end of the recording so far, nil once it stopped. `show`: the words to put next to 🤫.
    init(recorded: @escaping () -> [Float]?, engine: @escaping () -> SpeechEngine?,
         enabled: @escaping () -> Bool = { LiveText.isOn() }, show: @escaping (String) -> Void) {
        self.recorded = recorded
        self.engine = engine
        self.enabled = enabled
        self.show = show
    }

    static func supports(_ engine: SpeechEngine) -> Bool { engine is ParakeetEngine }

    /// When recording starts. `tick` is how often LiveText is asked whether a pass is due; nil when the caller
    /// ticks itself (E2E).
    func start(at t: TimeInterval = ProcessInfo.processInfo.systemUptime, tick: TimeInterval? = 0.25) {
        stop()
        guard enabled() else { return }
        state.start(at: t)
        guard let tick else { return }
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(at: ProcessInfo.processInfo.systemUptime) }
        }
    }

    /// Release, Esc, too short: no more passes, and the one in flight is dropped.
    func stop() {
        timer?.invalidate()
        timer = nil
        state.stop()
    }

    func tick(at t: TimeInterval) {
        guard let samples = recorded() else { return stop() }  // stopped without a stop, e.g. a failed save
        guard let engine = engine(), Self.supports(engine), let pass = state.pass(samples, at: t) else { return }
        self.pass = Task { [weak self] in
            let text = try? await engine.transcribe(pass.samples, wav: URL(fileURLWithPath: "/dev/null"))
            guard let self, let tail = self.state.finished(pass.id, text: text) else { return }
            self.shown += 1
            self.show(tail)
        }
    }
}
