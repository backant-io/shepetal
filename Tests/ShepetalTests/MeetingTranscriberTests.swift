import AVFoundation
import XCTest
import ShepetalCore
@testable import Shepetal

/// Cutting a channel into utterances. Pure: no model, no files.
final class UtterancesTests: XCTestCase {
    let rate = 16_000

    func tone(_ seconds: Double, _ amp: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) * 0.2)) * amp }
    }

    func quiet(_ seconds: Double) -> [Float] { tone(seconds, 0.001) }  // a mic's noise floor, not speech

    // Lengths are multiples of 1.2 s, so speech starts and ends on a 30 ms frame edge.
    // Each utterance becomes its own segment, with 0.2 s kept on both sides so no word edge is cut off.
    func testSplitsAtPausesWithPadding() {
        let s = quiet(1.2) + tone(1.8) + quiet(1.2) + tone(1.2) + quiet(1.2)
        let (spans, done) = Utterances.cut(s, final: true)
        XCTAssertEqual(spans, [16_000..<51_200, 64_000..<89_600])
        XCTAssertEqual(done, s.count)
    }

    // While recording, speech still running at the end waits for the next pass instead of being cut mid-word.
    func testLeavesAnUnfinishedUtteranceForTheNextPass() {
        let s = quiet(1.2) + tone(1.2) + quiet(1.2) + tone(1.2)
        let (spans, done) = Utterances.cut(s, final: false)
        XCTAssertEqual(spans, [16_000..<41_600])
        XCTAssertEqual(done, 54_400)
        let rest = Array(s[done...]) + quiet(1.2)
        // The next pass starts with the kept lead-in and gets the whole second utterance, plus up to a frame.
        let next = Utterances.cut(rest, final: false).spans
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.first?.lowerBound, 0)
        XCTAssertEqual(Double(next.first?.upperBound ?? 0), 25_600, accuracy: 480)
    }

    // Nobody talks for 30 s straight without a breath; when the level never drops that long, the utterance is
    // cut at its quietest moment, and the next one starts exactly there so no word is transcribed twice.
    func testCapsLongSpeechAt30sAtItsQuietestPointWithoutOverlap() {
        let s = tone(27) + [Float](repeating: 0, count: 3 * 480) + tone(18 - 0.09)
        let (spans, _) = Utterances.cut(s, final: true)
        XCTAssertEqual(spans, [0..<432_000, 432_000..<s.count])
    }

    func testSilenceGivesNoUtterances() {
        let s = quiet(9.6)
        XCTAssertEqual(Utterances.cut(s, final: false).spans, [])
        XCTAssertEqual(Utterances.cut(s, final: false).done, s.count - Utterances.pad)  // keeps the lead-in of what comes next
        XCTAssertEqual(Utterances.cut(s, final: true).done, s.count)
        XCTAssertEqual(Utterances.cut([], final: true).spans, [])
    }
}

/// The transcriber on real WAV files as the recorder writes them, with a stub model and summarizer.
@MainActor
final class MeetingTranscriberTests: XCTestCase {
    final class StubEngine: SpeechEngine {
        let name = "stub"
        var calls: [Int] = []
        var failNext = false
        /// What the model "hears", one per utterance in call order; " wordN " once it runs out.
        var texts: [String] = []
        func transcribe(_ samples: [Float], wav: URL) async throws -> String {
            if failNext { failNext = false; throw SpeechError("model failed") }
            calls.append(samples.count)
            return texts.isEmpty ? " word\(calls.count) " : texts.removeFirst()
        }
    }

    final class StubSummarizer: MeetingSummarizing {
        var got: [Segment]?
        func summarize(_ segments: [Segment]) -> Summary {
            got = segments
            return Summary(overview: "o", actionItems: [ActionItem(owner: "Me", task: "t")])
        }
    }

    var root: URL!
    var store: MeetingStore!
    let engine = StubEngine()
    let summarizer = StubSummarizer()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-transcriber-\(UUID().uuidString)")
        try AudioStore.makeOwnerOnlyDirectory(root)
        store = try MeetingStore(path: root.appendingPathComponent("meetings.sqlite"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Speech-level tone in `on` (seconds), silence elsewhere.
    func audio(_ seconds: Double, rate: Double, on: [ClosedRange<Double>]) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            on.contains { $0.contains(Double(i) / rate) } ? Float(sin(Double(i) * 0.2 * 16_000 / rate)) * 0.1 : 0
        }
    }

    func meeting(others: Bool = true) throws -> Meeting {
        let m = Meeting(id: "m1", app: "Zoom", startedAt: Date(), meAudioPath: root.appendingPathComponent("Me.wav").path,
                        othersAudioPath: others ? root.appendingPathComponent("Others.wav").path : "")
        try store.save(m)
        return m
    }

    /// Me: 16 kHz float WAV whose header still says 0 samples, appended to. Others: 48 kHz stereo float through
    /// AVAudioFile, as the Core Audio tap writes it, kept open (header not final) until `close`.
    final class Recording {
        let me: URL
        var others: AVAudioFile?
        init(_ m: Meeting) throws {
            me = URL(fileURLWithPath: m.meAudioPath)
            FileManager.default.createFile(atPath: me.path, contents: AudioStore.wav([]))
            if !m.othersAudioPath.isEmpty {
                let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
                others = try AVAudioFile(forWriting: URL(fileURLWithPath: m.othersAudioPath), settings: f.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: true)
            }
        }

        func write(me samples: [Float], others stereo: [Float]) throws {
            let h = try FileHandle(forWritingTo: me)
            try h.seekToEnd()
            try h.write(contentsOf: samples.withUnsafeBufferPointer { Data(buffer: $0) })
            try h.close()
            guard let others, !stereo.isEmpty else { return }
            let b = AVAudioPCMBuffer(pcmFormat: others.processingFormat, frameCapacity: AVAudioFrameCount(stereo.count))!
            b.frameLength = AVAudioFrameCount(stereo.count)
            let p = b.floatChannelData![0]
            for (i, x) in stereo.enumerated() { p[2 * i] = x; p[2 * i + 1] = x }
            try others.write(from: b)
        }

        func close(me all: [Float]) {
            others = nil
            FileManager.default.createFile(atPath: me.path, contents: AudioStore.wav(all))
        }
    }

    // Live passes store the utterances that have ended while the meeting runs; finish adds the rest. Each
    // utterance is heard once, gets its channel's speaker and its time in the meeting, and the summary sees
    // the whole meeting in time order.
    func testLiveThenFinalGivesTimedSegmentsPerSpeakerAndASummary() async throws {
        let m = try meeting()
        let me = audio(14, rate: 16_000, on: [1...3, 10...12])
        let others = audio(14, rate: 48_000, on: [5...7])
        let rec = try Recording(m)
        let t = MeetingTranscriber(meeting: m, engine: engine, store: store, summarizer: summarizer)

        try rec.write(me: Array(me[..<128_000]), others: Array(others[..<384_000]))  // 8 s recorded so far
        let live = try await t.poll()
        XCTAssertEqual(live.map(\.speaker), [.me, .others])
        XCTAssertEqual(try store.get(m.id)?.segments.count, 2, "live segments are stored before the meeting ends")
        XCTAssertNil(summarizer.got, "no summary while the meeting runs")

        try rec.write(me: Array(me[128_000...]), others: Array(others[384_000...]))
        rec.close(me: me)
        let r = try await t.finish()

        XCTAssertEqual(r.segments.map(\.speaker), [.me, .others, .me])
        XCTAssertEqual(engine.calls.count, 3, "each utterance is transcribed once")
        let expected: [(Double, Double)] = [(0.8, 3.2), (4.8, 7.2), (9.8, 12.2)]
        for (s, e) in zip(r.segments, expected) {
            XCTAssertEqual(s.start, e.0, accuracy: 0.05, "\(s)")
            XCTAssertEqual(s.end, e.1, accuracy: 0.05, "\(s)")
            XCTAssertFalse(s.text.hasPrefix(" ") || s.text.hasSuffix(" "))
        }
        XCTAssertEqual(summarizer.got, r.segments)
        XCTAssertEqual(try store.get(m.id)?.summary?.actionItems, [ActionItem(owner: "Me", task: "t")])
        XCTAssertEqual(try store.get(m.id)?.segments, r.segments)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".utterance.wav").path))
    }

    // On laptop speakers the mic hears the call again, so the model transcribes the other side's line as Me
    // too. That copy must not reach the transcript, the search or the summary (else Me gets a second copy of the
    // other side's action items), while Me talking over them in its own words stays and the audio is kept as
    // recorded (rule 4).
    func testCallEchoOnTheMicIsDroppedButOwnCrosstalkIsKept() async throws {
        let m = try meeting()
        // 5...7 is the echo of the other side; 13 is a quiet bit of it, too short to be a word Me said.
        let me = audio(17, rate: 16_000, on: [1...3, 5...7, 9...11, 13...13.05])
        let others = audio(17, rate: 48_000, on: [5...7, 9...11, 12...14])
        // Per pass the Me channel is transcribed first, then Others. The quieter echo is misheard.
        engine.texts = ["Thanks for joining, everyone.", "Sure the bita build is ready", "Yes, that works for me.", "Bang.",
                        "Sure, the beta build is ready.", "I will fix the login crash by Wednesday.", "Thanks, everyone."]
        let rec = try Recording(m)
        let t = MeetingTranscriber(meeting: m, engine: engine, store: store, summarizer: summarizer)
        try rec.write(me: me, others: others)
        let live = try await t.poll()
        rec.close(me: me)
        let wav = try Data(contentsOf: URL(fileURLWithPath: m.meAudioPath))
        let r = try await t.finish()

        let expected = [Speaker.me: ["Thanks for joining, everyone.", "Yes, that works for me."],
                        .others: ["Sure, the beta build is ready.", "I will fix the login crash by Wednesday.", "Thanks, everyone."]]
        for segs in [live, r.segments, try store.get(m.id)?.segments ?? [], summarizer.got ?? []] {
            XCTAssertEqual(segs.filter { $0.speaker == .me }.map(\.text), expected[.me])
            XCTAssertEqual(segs.filter { $0.speaker == .others }.map(\.text), expected[.others])
        }
        XCTAssertEqual(engine.calls.count, 7)
        XCTAssertTrue(try store.search("bita", limit: 10).isEmpty, "the echo's text is out of the search index")
        XCTAssertEqual(try store.search("beta", limit: 10).map(\.id), [m.id])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: m.meAudioPath)), wav, "the mic audio is kept as recorded")
    }

    // A model error must not lose speech: the utterance stays pending and is transcribed by a later pass.
    func testFailedTranscriptionKeepsTheAudioForTheNextPass() async throws {
        let m = try meeting()
        let me = audio(5, rate: 16_000, on: [1...2])
        let rec = try Recording(m)
        let t = MeetingTranscriber(meeting: m, engine: engine, store: store, summarizer: summarizer)
        try rec.write(me: me, others: audio(5, rate: 48_000, on: [3...4]))
        engine.failNext = true
        do { _ = try await t.poll(); XCTFail("the error is reported") } catch {}
        XCTAssertEqual(try store.get(m.id)?.segments.count, 0)
        rec.close(me: me)
        let r = try await t.finish()
        XCTAssertEqual(r.segments.map(\.speaker), [.me, .others])
        XCTAssertEqual(engine.calls.count, 2)
    }

    // Without System Audio Recording the recorder writes only Me.wav and passes "" for Others.
    func testMicOnlyMeetingIsTranscribed() async throws {
        let m = try meeting(others: false)
        let me = audio(3, rate: 16_000, on: [1...1.3])
        let rec = try Recording(m)
        try rec.write(me: me, others: [])
        rec.close(me: me)
        let r = try await MeetingTranscriber(meeting: m, engine: engine, store: store, summarizer: summarizer).finish()
        XCTAssertEqual(r.segments.map(\.speaker), [.me])
        XCTAssertEqual(engine.calls, [16_000], "a short utterance is padded to the 1 s the model needs")
    }

    // A channel the recorder said it wrote but that is gone is an error, not an empty transcript.
    func testMissingAudioFileFails() async throws {
        let m = try meeting()
        let t = MeetingTranscriber(meeting: m, engine: engine, store: store, summarizer: summarizer)
        do { _ = try await t.finish(); XCTFail("missing audio is reported") } catch {
            XCTAssertTrue("\(error)".contains("Me.wav"), "\(error)")
        }
        XCTAssertNil(summarizer.got)
    }
}
