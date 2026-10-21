import Foundation
import ShepetalCore
import ShepetalSummary

/// Recorder → store → transcriber → summary, with the 🤫 hints for it. A meeting is stored from its first second,
/// so the Meetings tab (it polls the same store) lists it while it records; live segments land every 30 s, the
/// rest and the summary when it ends. The audio stays where the recorder wrote it (rule 4).
@MainActor
final class MeetingFlow {
    let store: MeetingStoring
    private let summarizer: MeetingSummarizing
    private let engine: () -> SpeechEngine?
    private let hint: (String) -> Void
    private let liveEvery: Double
    private var transcriber: MeetingTranscriber?
    /// The final pass of the meeting that ended last.
    private(set) var finishing: Task<Void, Never>?
    /// True while a meeting records (the menu bar shows it for the whole meeting).
    var onRecording: (Bool) -> Void = { _ in }
    /// A recorded meeting's whole transcript is stored and its summary follows (the transcript window opens).
    /// `summarizing` false: the final pass or the summary failed, so no summary follows; what was stored opens.
    var onTranscript: (_ meeting: Meeting, _ summarizing: Bool) -> Void = { _, _ in }

    init(store: MeetingStoring, summarizer: MeetingSummarizing, engine: @escaping () -> SpeechEngine?,
         hint: @escaping (String) -> Void, liveEvery: Double = MeetingTranscriber.chunkSeconds) {
        self.store = store
        self.summarizer = summarizer
        self.engine = engine
        self.hint = hint
        self.liveEvery = liveEvery
    }

    /// The app's flow: meetings.sqlite in the owner-only data dir, the one `--e2e-meeting` checks.
    static func onDisk(engine: @escaping () -> SpeechEngine?, hint: @escaping (String) -> Void) throws -> MeetingFlow {
        try AudioStore.makeOwnerOnlyDirectory(Paths.root)
        return MeetingFlow(store: try MeetingStore(path: Paths.root.appendingPathComponent("meetings.sqlite")),
                           summarizer: try MeetingSummarizer(), engine: engine, hint: hint)
    }

    func attach(_ recorder: MeetingRecorder) {
        recorder.onStarted = { [weak self] in self?.started($0) }
        recorder.onEnded = { [weak self] in self?.ended($0) }
        recorder.onDiscarded = { [weak self] in self?.discarded($0) }
    }

    func started(_ m: Meeting) {
        onRecording(true)
        do { try store.save(m) } catch { return hint("Meeting not stored: \(error.localizedDescription)") }
        // No model yet (it loads at launch): the final pass transcribes the whole meeting instead.
        transcriber = makeTranscriber(m)
        transcriber?.startLive(every: liveEvery)
    }

    func ended(_ m: Meeting) {
        onRecording(false)
        // ponytail: the live transcriber keeps the channels it started with; the recorder only drops a channel
        // when no file was written at all, which is the discard below.
        let t = transcriber ?? makeTranscriber(m)
        transcriber = nil
        do { try store.save(m) } catch { return hint("Meeting not stored: \(error.localizedDescription)") }
        guard let t else { return hint("Meeting saved · no speech model to transcribe it yet") }
        let previous = finishing
        finishing = Task { [weak self, hint] in
            await previous?.value  // one meeting's final pass at a time
            do {
                _ = try await t.finish { self?.onTranscript(m, true) }
                hint("Meeting notes ready · open Shepetal → Meetings")
            } catch {
                hint("Meeting transcription failed: \(error.localizedDescription)")
                self?.onTranscript(m, false)
            }
        }
    }

    /// Ended without any audio: the recorder keeps nothing, so the list does not either.
    func discarded(_ m: Meeting) {
        onRecording(false)
        transcriber = nil  // its live loop holds it weakly and stops
        try? store.delete(m.id)
    }

    private func makeTranscriber(_ m: Meeting) -> MeetingTranscriber? {
        engine().map { MeetingTranscriber(meeting: m, engine: $0, store: store, summarizer: summarizer) }
    }
}
