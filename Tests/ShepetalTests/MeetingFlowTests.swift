import XCTest
import MeetingCore
import ShepetalCore
@testable import Shepetal

/// The wired meeting path: detector → recorder → store → live and final transcription → summary → Meetings tab,
/// on real WAV files written the way a recording grows, with a stub model and summarizer. No mic, no TCC.
@MainActor
final class MeetingFlowTests: XCTestCase {
    /// Me.wav and Others.wav as a recording writes them: a header that still says 0 samples, appended audio,
    /// and the final header at stop.
    final class WavCapture: MeetingCapturing {
        var writes = true
        private var dir: URL?
        private var audio: [String: [Float]] = ["Me": [], "Others": []]

        func start(dir: URL) throws -> Bool {
            self.dir = dir
            if writes { for name in audio.keys { try AudioStore.wav([]).write(to: url(name)) } }
            return true
        }

        func append(me: [Float], others: [Float]) throws {
            for (name, s) in [("Me", me), ("Others", others)] {
                audio[name]! += s
                let h = try FileHandle(forWritingTo: url(name))
                try h.seekToEnd()
                try h.write(contentsOf: s.withUnsafeBufferPointer { Data(buffer: $0) })
                try h.close()
            }
        }

        func stop() throws {
            if writes { for (name, s) in audio { try AudioStore.wav(s).write(to: url(name)) } }
        }

        private func url(_ name: String) -> URL { dir!.appendingPathComponent("\(name).wav") }
    }

    private var root: URL!
    private var store: MeetingStore!
    private var capture: WavCapture!
    private var recorder: MeetingRecorder!
    private var flow: MeetingFlow!
    private let engine = MeetingTranscriberTests.StubEngine()
    private let summarizer = MeetingTranscriberTests.StubSummarizer()
    private var hints: [String] = []
    private var recording: [Bool] = []
    /// What the transcript window would show when the flow opens it, and whether a summary is still coming.
    private var opened: [MeetingRecord?] = []
    private var summarizing: [Bool] = []
    private let zoom = Snapshot(micUsers: [MicUser(pid: 100, bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us")])

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-flow-\(UUID().uuidString)")
        try AudioStore.makeOwnerOnlyDirectory(root)
        store = try MeetingStore(path: root.appendingPathComponent("meetings.sqlite"))
        capture = WavCapture()
        recorder = MeetingRecorder(dir: root.appendingPathComponent("meetings"), capture: capture,
                                   detector: MeetingDetector(ownPID: getpid()), autoRecord: { false }, silenceEnd: 20,
                                   card: { _ in }) { [unowned self] in hints.append($0) }
        connect(self.engine)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func connect(_ engine: @escaping @autoclosure () -> SpeechEngine?) {
        flow = MeetingFlow(store: store, summarizer: summarizer, engine: engine,
                           hint: { [unowned self] in hints.append($0) }, liveEvery: 0.05)
        flow.onRecording = { [unowned self] in recording.append($0) }
        flow.onTranscript = { [unowned self] in opened.append(try? store.get($0.id)); summarizing.append($1) }
        flow.attach(recorder)
    }

    /// 16 kHz: speech-level tone in `on`, silence elsewhere.
    private func audio(_ seconds: Double, on: ClosedRange<Double>? = nil) -> [Float] {
        (0..<Int(seconds * 16_000)).map { i in on?.contains(Double(i) / 16_000) == true ? Float(sin(Double(i) * 0.2)) * 0.1 : 0 }
    }

    private func until(_ what: String, _ done: () throws -> Bool) async throws {
        for _ in 0..<200 where try !done() { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(try done(), what)
    }

    func testDetectedMeetingShowsLiveInTheTabThenGetsItsTranscriptAndSummaryWithTheAudioKept() async throws {
        let tab = MeetingsModel(store: store, copy: { _ in })
        for t in 0...5 { recorder.update(zoom, now: Double(t)) }
        recorder.record()  // the click on the card
        tab.refresh()
        let listed = try XCTUnwrap(tab.record, "the meeting is in the Meetings tab from its first second")
        XCTAssertEqual(listed.meeting.app, "zoom.us")
        XCTAssertNil(listed.meeting.endedAt)
        XCTAssertEqual(recording, [true])

        try capture.append(me: audio(4, on: 0.5...1.5), others: audio(4))
        try await until("a live pass stores Me's utterance while the meeting runs") {
            try store.get(listed.meeting.id)?.segments.count == 1
        }
        tab.refresh()
        XCTAssertEqual(tab.record?.segments.map(\.speaker), [.me])
        XCTAssertNil(tab.record?.summary, "no summary before the meeting ends")
        XCTAssertEqual(opened.count, 0, "the transcript window waits for the meeting to end")

        try capture.append(me: audio(4), others: audio(4, on: 0.5...1.5))
        for t in 6...40 { recorder.update(Snapshot(), now: Double(t)) }  // Zoom let go of the mic
        XCTAssertNil(recorder.current)
        await flow.finishing?.value

        tab.refresh()
        let r = try XCTUnwrap(tab.record)
        XCTAssertNotNil(r.meeting.endedAt, "stored as ended")
        XCTAssertEqual(r.segments.map(\.speaker), [.me, .others])
        XCTAssertEqual(r.segments.last?.start ?? 0, 4.3, accuracy: 0.05, "Others' line is at its time in the meeting")
        XCTAssertEqual(engine.calls.count, 2, "the utterance done live is not transcribed again")
        XCTAssertEqual(summarizer.got, r.segments, "the summary sees the whole meeting")
        XCTAssertEqual(summarizer.onMain, false, "a long summary must not hold up fn and the indicator")
        // The window opens once, with the whole transcript and before the summary, so it never waits for it.
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first??.segments, r.segments)
        XCTAssertNil(opened.first??.summary)
        XCTAssertEqual(summarizing, [true])
        XCTAssertEqual(r.summary?.actionItems, [ActionItem(owner: "Me", task: "t")])
        XCTAssertEqual(hints, ["Meeting detected · recording", "Meeting recording saved", "Meeting notes ready · open Shepetal → Meetings"])
        XCTAssertEqual(recording, [true, false])
        for path in [r.meeting.meAudioPath, r.meeting.othersAudioPath] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "meeting audio is kept (rule 4): \(path)")
        }
    }

    // The model loads after launch; a meeting that started before it is transcribed in full when it ends.
    func testMeetingStartedBeforeTheModelLoadedIsTranscribedWhenItEnds() async throws {
        var loaded: SpeechEngine?
        connect(loaded)
        recorder.start()
        try capture.append(me: audio(3, on: 0.5...1.5), others: audio(3))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(engine.calls, [], "nothing to transcribe with yet")
        loaded = engine
        recorder.stop()
        await flow.finishing?.value
        let r = try XCTUnwrap(try store.list(limit: 5).first.flatMap { try store.get($0.id) })
        XCTAssertEqual(r.segments.map(\.speaker), [.me])
        XCTAssertNotNil(r.summary)
    }

    // The model fails on the last utterance: what was stored still opens, with no "Summarizing…" left spinning.
    func testFailedFinalPassStillOpensTheWindowWithoutPromisingASummary() async throws {
        var loaded: SpeechEngine?
        connect(loaded)
        recorder.start()
        try capture.append(me: audio(3, on: 0.5...1.5), others: audio(3))
        loaded = engine
        engine.failNext = true
        recorder.stop()
        await flow.finishing?.value
        XCTAssertEqual(hints.last, "Meeting transcription failed: model failed")
        XCTAssertEqual(opened.count, 1)
        XCTAssertNil(opened.first??.summary)
        XCTAssertEqual(summarizing, [false])
    }

    func testWithoutAModelTheMeetingIsStillSavedAsEnded() throws {
        connect(nil)
        recorder.start()
        recorder.stop()
        let m = try XCTUnwrap(try store.list(limit: 5).first)
        XCTAssertNotNil(m.endedAt)
        XCTAssertNil(flow.finishing)
        XCTAssertEqual(hints.last, "Meeting saved · no speech model to transcribe it yet")
        XCTAssertEqual(opened.count, 0, "no transcript, no window")
    }

    // Audio but nobody spoke: the window still opens, says no speech was recorded and links to the record.
    func testSilentMeetingStillOpensTheTranscriptWindow() async throws {
        recorder.start()
        try capture.append(me: audio(2), others: audio(2))
        recorder.stop()
        await flow.finishing?.value
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first??.segments, [])
    }

    // F67: nobody speaks for the silence end (20 s here). The live pass hears it in the growing WAVs and the
    // recording ends by itself, then it is stored, transcribed and kept like a meeting that ended by hand.
    func testRecordingNobodySpeaksInEndsByItselfAndIsKept() async throws {
        recorder.start()
        let id = try XCTUnwrap(recorder.current?.id)
        try capture.append(me: audio(21), others: audio(21))
        try await until("a live pass ends the recording after 20 s of quiet") { recorder.current == nil }
        await flow.finishing?.value
        XCTAssertEqual(hints, ["Recording meeting", "Meeting ended · no one spoke for 20 s", "Meeting notes ready · open Shepetal → Meetings"])
        XCTAssertEqual(recording, [true, false])
        let r = try XCTUnwrap(try store.get(id))
        XCTAssertNotNil(r.meeting.endedAt, "stored as ended")
        XCTAssertEqual(opened.count, 1, "the transcript window opens as after any meeting")
        for path in [r.meeting.meAudioPath, r.meeting.othersAudioPath] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the audio is kept as recorded (rule 4): \(path)")
        }
    }

    // Others speaks at the end of 25 s in which Me is quiet: the model hears a word, so it goes on.
    func testSpeechInTheRecordedAudioKeepsTheRecordingGoing() async throws {
        recorder.start()
        try capture.append(me: audio(25), others: audio(25, on: 20...21))
        try await until("the live pass reads both channels and transcribes Others' line") { engine.calls.count == 1 }
        XCTAssertNotNil(recorder.current, "Others spoke 4 s ago")
        try capture.append(me: audio(21), others: audio(21))
        try await until("then 20 s of quiet on both ends it") { recorder.current == nil }
        XCTAssertEqual(hints.dropFirst().first, "Meeting ended · no one spoke for 20 s")
    }

    // A key or a cough is loud, but no one spoke: the model hears no words (or only prints a tag for it), so the
    // sound does not keep a silent meeting going. A level floor would hear it as speech, and on a real mic the
    // room is always above that floor, so the meeting would never end.
    func testSoundTheModelHearsNoWordsInIsNotSpeech() async throws {
        engine.texts = ["[BLANK_AUDIO]", "(noise)"]
        recorder.start()
        try capture.append(me: audio(21, on: 3...4), others: audio(21, on: 10...11))
        try await until("the live pass hears only sound and ends the recording") { recorder.current == nil }
        XCTAssertEqual(engine.calls.count, 2, "both sounds went to the model")
        XCTAssertEqual(hints.dropFirst().first, "Meeting ended · no one spoke for 20 s")
    }

    // The recorder keeps nothing when no audio was written, so the tab must not keep an empty meeting either.
    func testMeetingWithNoAudioLeavesTheListAndTheSearchIndex() throws {
        capture.writes = false
        recorder.start()
        XCTAssertEqual(try store.list(limit: 5).count, 1, "listed while it records")
        recorder.stop()
        XCTAssertEqual(try store.list(limit: 5).count, 0)
        XCTAssertEqual(try store.search("Manual", limit: 5).count, 0)
        XCTAssertEqual(hints.last, "Meeting not saved: no audio was captured")
        XCTAssertEqual(opened.count, 0, "nothing kept, no window")
        XCTAssertEqual(recording, [true, false])
    }
}
