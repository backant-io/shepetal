import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

private func scratch(_ name: String) -> URL {
    let base = ProcessInfo.processInfo.environment["SHEPETAL_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

/// Pavel's history after double-tapping fn (2026-10-20): a "failed" row with 0 samples, then a "too short" row
/// 0.7 s later, again and again. Opening the mic held the main thread past the 500 ms hold threshold, so the
/// first tap's release, read late and timed by the clock at that moment, counted as a hold: the recording
/// stopped before the mic gave one sample, and the second tap started a new recording.
/// These replays send fn through the real FnTap into a Dictation whose mic takes 0.6 s to open on the thread
/// that reads fn, as the old Recorder did. Each change carries the time the keyboard sent it.
final class FnReplayTests: XCTestCase {
    private var root: URL!
    private var history: History!
    private var dictation: Dictation!
    private let tap = FnTap()
    private var opens = 0
    private var closes = 0
    private var transcribed: [[Float]] = []
    private var actions: [GestureAction] = []
    private let mic: [Float] = [0.25, -0.5, 0.125]

    override func setUpWithError() throws {
        root = scratch("fn-replay")
        try AudioStore.makeOwnerOnlyDirectory(root)
        history = try History(path: root.appendingPathComponent("history.sqlite"))
        dictation = Dictation(store: try AudioStore(dir: root.appendingPathComponent("audio")), history: history,
                              startMic: { [unowned self] in opens += 1; Thread.sleep(forTimeInterval: 0.6) },
                              stopMic: { [unowned self] in closes += 1; return mic },
                              transcribe: { [unowned self] in transcribed.append($0) })
        tap.onInput = { [unowned self] input, t in
            actions += try! dictation.run { $0.handle(input, at: t) }
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `changes` are (ms after the first press, fn down). A change is sent when its time comes and read as
    /// soon as the reading thread is free. The short-press timer fires at its deadline unless a change came first.
    /// `globe` also sends the Globe key's keycode 179 keyDown and keyUp right after each release, as macOS does.
    private func replay(_ changes: [(ms: Double, down: Bool)], globe: Bool = false) throws {
        let t0 = ProcessInfo.processInfo.systemUptime
        for (ms, down) in changes {
            let at = t0 + ms / 1000
            if let deadline = settle, deadline < at { try tick(at: deadline) }
            wait(until: at)
            tap.handle(.flagsChanged, fnEvent(down: down, at: at))
            if globe, !down {
                for type in [CGEventType.keyDown, .keyUp] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(Key.globe), keyDown: type == .keyDown)!
                    e.timestamp = CGEventTimestamp(at * 1e9)
                    e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)  // not our own event
                    tap.handle(type, e)
                }
            }
        }
        if let deadline = settle { try tick(at: deadline) }
    }

    private var handsFree: Bool { if case .handsFree = dictation.gesture.state { true } else { false } }
    /// The short-press timer; the 20 min length cap is not part of a replay.
    private var settle: TimeInterval? { if case .awaitingSecondTap(_, let d) = dictation.gesture.state { d } else { nil } }

    private func tick(at deadline: TimeInterval) throws {
        wait(until: deadline)
        actions += try dictation.run { $0.tick(at: ProcessInfo.processInfo.systemUptime) }
    }

    private func wait(until t: TimeInterval) {
        let s = t - ProcessInfo.processInfo.systemUptime
        if s > 0 { Thread.sleep(forTimeInterval: s) }
    }

    private func fnEvent(down: Bool, at t: TimeInterval) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(Key.fn), keyDown: down)!
        e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)  // not our own event
        e.type = .flagsChanged
        e.flags = down ? .maskSecondaryFn : []
        e.timestamp = CGEventTimestamp(t * 1e9)
        return e
    }

    /// Hands-free is one recording: the mic opened once at the first press, never restarted, and the samples
    /// went to the transcriber once, when the ending tap came.
    private func assertOneCapture(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actions, [.start, .lockHandsFree, .stop], file: file, line: line)
        XCTAssertEqual(opens, 1, "the second tap must not restart the mic", file: file, line: line)
        XCTAssertEqual(closes, 1, file: file, line: line)
        XCTAssertEqual(transcribed, [mic], file: file, line: line)
        XCTAssertEqual(try history.recent(), [], "no too-short row for a double-tap", file: file, line: line)
    }

    func testFastDoubleTapStartsHandsFree() throws {
        try replay([(0, true), (120, false), (270, true), (390, false)])  // 120 ms press, 150 ms gap
        XCTAssertTrue(handsFree)
        XCTAssertEqual(transcribed, [], "the first tap was read as a hold")
        try replay([(0, true), (100, false)])  // the tap that ends hands-free
        assertOneCapture()
    }

    func testSlowDoubleTapStartsHandsFree() throws {
        try replay([(0, true), (350, false), (750, true), (850, false)])  // 350 ms press, 400 ms gap
        XCTAssertTrue(handsFree)
        try replay([(0, true), (100, false)])
        assertOneCapture()
    }

    // Pavel (2026-10-21, on a build from before this replay existed): "it does not do the transcript until I press
    // fn again". A 40 ms tap read after the 0.6 s mic open was timed as a hold. With 40 ms taps and a 50 ms gap,
    // hands-free must lock on the second press with nothing pending, and the ending tap must transcribe on its
    // press, before its release and without a timer or another fn event.
    func testQuickDoubleTapThenOneTapTranscribesOnThePress() throws {
        try replay([(0, true), (40, false), (90, true), (130, false)])
        XCTAssertTrue(handsFree)
        XCTAssertNil(settle, "no short-press timer waits in hands-free")
        try replay([(0, true)])
        XCTAssertEqual(transcribed, [mic], "the ending tap's press transcribes")
        try replay([(40, false)])
        assertOneCapture()
    }

    // Pavel's hand test (2026-10-21): "M-FN-3 starting the hands free mode instead" and "M-FN-2 not working at all".
    // macOS also sends each Globe press as keycode 179 key events after the release, and they were read as a second
    // tap. A short press must never enter hands-free: it is too short, the hint shows, and nothing is transcribed.
    func testGlobeEventsNeverTurnAShortPressIntoHandsFree() throws {
        try replay([(0, true), (40, false)], globe: true)
        XCTAssertEqual(actions, [.start, .tooShort], "a short press is too short, never hands-free")
        XCTAssertEqual(dictation.gesture.state, .idle)
        XCTAssertEqual(transcribed, [])
        XCTAssertEqual(try history.recent().map(\.outcome), [.tooShort])
    }

    // The same events around a quick double-tap and the ending tap: hands-free locks once, the ending tap
    // transcribes on its press, and no new recording or too-short row follows it.
    func testGlobeEventsKeepDoubleTapAndEndingTapIntact() throws {
        try replay([(0, true), (40, false), (90, true), (130, false)], globe: true)
        XCTAssertTrue(handsFree)
        try replay([(0, true), (40, false)], globe: true)
        assertOneCapture()
        XCTAssertEqual(dictation.gesture.state, .idle)
    }

    // Tap, then hold the second press: hands-free locks on the second press and its release keeps recording.
    func testTapThenHoldStaysHandsFree() throws {
        try replay([(0, true), (120, false), (270, true), (1200, false)])
        XCTAssertTrue(handsFree)
        try replay([(0, true), (100, false)])
        assertOneCapture()
    }

    func testHoldTranscribesOnRelease() throws {
        try replay([(0, true), (1000, false)])
        XCTAssertEqual(actions, [.start, .stop])
        XCTAssertEqual(transcribed, [mic])
    }

    // A lone tap is "too short" only once the double-tap window has passed: no transcription, audio kept.
    func testTapIsTooShortAfterTheWindow() throws {
        try replay([(0, true), (120, false)])
        XCTAssertEqual(actions, [.start, .tooShort])
        XCTAssertEqual(transcribed, [])
        XCTAssertEqual(try history.recent().map(\.outcome), [.tooShort])
        XCTAssertEqual(opens, 1)
    }
}

/// SpeechGuard (F51) alone decides what reaches the model; a recording with no samples at all (the mic did
/// not open in time) only gets its own wording, so the user knows the mic, not their voice, was the problem.
@MainActor
final class NoAudioPipelineTests: XCTestCase {
    func testNoSamplesSayNoAudioAndSilenceSaysNoSpeech() async throws {
        let root = scratch("no-audio")
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let engine = CountingEngine()

        for (samples, message) in [([Float](), MicAudio.noAudio), ([Float](repeating: 0, count: 8000), "No speech heard")] {
            let run = await pipeline.process(samples, engine: engine, context: { ("", "") }, sendPaste: { _ in
                XCTFail("nothing may be pasted")
            })
            XCTAssertEqual(run.error, message)
            XCTAssertEqual(run.entry.outcome, .noSpeech, "one outcome for both, as on main")
            XCTAssertTrue(FileManager.default.fileExists(atPath: run.entry.audioPath), "the audio is kept (rule 4)")
        }
        XCTAssertEqual(engine.calls, 0)

        // Speech after the mic's warm-up zeros (about 130 ms on Pavel's Mac) is speech.
        let warmUp = [Float](repeating: 0, count: 2076) + (0..<5769).map { Float(sin(Double($0) * 0.2)) * 0.05 }
        let run = await pipeline.process(warmUp, engine: engine, context: { ("", "") }, sendPaste: { _ in })
        XCTAssertEqual(engine.calls, 1)
        XCTAssertNotEqual(run.error, MicAudio.noAudio)
    }
}

private final class CountingEngine: SpeechEngine {
    let name = "stub"
    private(set) var calls = 0
    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        calls += 1
        return ""
    }
}
