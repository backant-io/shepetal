import Foundation

/// Carries out the fn gestures: opens and closes the mic, hands held recordings to the transcriber, and
/// keeps the audio of recordings that end without one (too short, cancelled) next to their history row.
/// The shell supplies the mic and the transcriber and draws the returned actions.
public final class Dictation {
    /// Settable for its config (`maxDuration`); its state only moves through `run`.
    public var gesture = FnGesture()
    private let store: AudioStore
    private let history: History
    private let startMic: () throws -> Void
    private let stopMic: () -> [Float]
    private let transcribe: ([Float]) -> Void
    private var recording = false

    public init(store: AudioStore, history: History, startMic: @escaping () throws -> Void,
                stopMic: @escaping () -> [Float], transcribe: @escaping ([Float]) -> Void) {
        self.store = store; self.history = history
        self.startMic = startMic; self.stopMic = stopMic; self.transcribe = transcribe
    }

    /// Feeds one event to the gesture, carries out its actions and returns them for the UI.
    /// Throws when the mic does not open (the gesture is reset) or the audio cannot be kept.
    @discardableResult
    public func run(_ event: (inout FnGesture) -> [GestureAction]) throws -> [GestureAction] {
        let actions = event(&gesture)
        for action in actions {
            switch action {
            case .start:
                do { try startMic() } catch { gesture.reset(); throw error }
                recording = true
            case .lockHandsFree, .warnDuration: break
            case .tooShort: try keep(as: .tooShort)
            case .cancel: try keep(as: .cancelled)
            case .stop: transcribe(stop())
            }
        }
        return actions
    }

    private func stop() -> [Float] {
        guard recording else { return [] }
        recording = false
        return stopMic()
    }

    private func keep(as outcome: Outcome) throws {
        let samples = stop()
        let id = UUID().uuidString
        let url = try store.save(samples, id: id)
        try history.add(HistoryEntry(id: id, createdAt: Date(), outcome: outcome, audioPath: url.path,
                                     durationMs: samples.count * 1000 / AudioStore.sampleRate))
    }
}
