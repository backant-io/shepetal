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
    private let zoom = Snapshot(micClients: [MicClient(bundleID: "us.zoom.xos", name: "zoom.us")])

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-flow-\(UUID().uuidString)")
        try AudioStore.makeOwnerOnlyDirectory(root)
        store = try MeetingStore(path: root.appendingPathComponent("meetings.sqlite"))
        capture = WavCapture()
        recorder = MeetingRecorder(dir: root.appendingPathComponent("meetings"), capture: capture,
                                   detector: MeetingDetector()) { [unowned self] in hints.append($0) }
        connect(self.engine)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func connect(_ engine: @escaping @autoclosure () -> SpeechEngine?) {
        flow = MeetingFlow(store: store, summarizer: summarizer, engine: engine,
                           hint: { [unowned self] in hints.append($0) }, liveEvery: 0.05)
        flow.onRecording = { [unowned self] in recording.append($0) }
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
        tab.refresh()
        let listed = try XCTUnwrap(tab.record, "the meeting is in the Meetings tab from its first second")
        XCTAssertEqual(listed.meeting.app, "Zoom")
        XCTAssertNil(listed.meeting.endedAt)
        XCTAssertEqual(recording, [true])

        try capture.append(me: audio(4, on: 0.5...1.5), others: audio(4))
        try await until("a live pass stores Me's utterance while the meeting runs") {
            try store.get(listed.meeting.id)?.segments.count == 1
        }
        tab.refresh()
        XCTAssertEqual(tab.record?.segments.map(\.speaker), [.me])
        XCTAssertNil(tab.record?.summary, "no summary before the meeting ends")

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

    func testWithoutAModelTheMeetingIsStillSavedAsEnded() throws {
        connect(nil)
        recorder.start()
        recorder.stop()
        let m = try XCTUnwrap(try store.list(limit: 5).first)
        XCTAssertNotNil(m.endedAt)
        XCTAssertNil(flow.finishing)
        XCTAssertEqual(hints.last, "Meeting saved · no speech model to transcribe it yet")
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
        XCTAssertEqual(recording, [true, false])
    }
}
