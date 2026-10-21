import AppKit
import AVFoundation
import FluidAudio
import ShepetalCore
import XCTest
@testable import Shepetal

/// A recorder with no hardware: the test feeds its buffers.
final class FedRecorder: Recorder {
    override func open(_ device: MicDevice?) throws {}

    private let buf: AVAudioPCMBuffer = {
        let buf = AVAudioPCMBuffer(pcmFormat: Resampler.format, frameCapacity: 1600)!
        buf.frameLength = 1600
        for i in 0..<1600 { buf.floatChannelData![0][i] = Float(sin(Double(i) * 0.2)) * 0.045 }  // speech level
        return buf
    }()

    func feed(seconds: Int) {
        for _ in 0..<(seconds * 10) { take(buf) }
    }
}

/// F13: the words next to 🤫 while recording. They must never become the inserted text (rule 8: only the final
/// pass, into the window that kept focus), must stop with the dictation, and run only on Parakeet, where a pass a
/// second is cheap enough not to hold up the final one. Hermetic: no model, no mic, a private pasteboard.
@MainActor
final class LiveCaptionTests: XCTestCase {
    private var heard: [Int] = []

    /// Parakeet with the model replaced: a 10 s window or less answers "only the end", the whole recording the rest.
    private func parakeet() -> ParakeetEngine {
        ParakeetEngine(recognize: { [unowned self] samples in
            heard.append(samples.count)
            let text = samples.count <= LiveText.windowSamples ? "only the end" : "every word from the start"
            return ASRResult(text: text, confidence: 0.9, duration: 1, processingTime: 0, tokenTimings: [])
        }, dictionary: { Vocabulary("") })
    }

    private let speech = LiveCaptionTests.speech
    private static let speech = (0..<12 * AudioStore.sampleRate).map { Float(sin(Double($0) * 0.2)) * 0.045 }

    func testPartialsShowOnParakeetOnly() async {
        var shown: [String] = []
        let live = LiveCaption(recorded: { [speech] in speech }, engine: { [self] in parakeet() }, enabled: { true }) { shown.append($0) }
        live.start(at: 0, tick: nil)
        live.tick(at: 1)
        await live.pass?.value
        XCTAssertEqual(shown, ["only the end"])
        XCTAssertEqual(heard, [LiveText.windowSamples], "the last 10 s, not the whole recording")

        let whisperLike = MeetingTranscriberTests.StubEngine()  // any engine but Parakeet
        let other = LiveCaption(recorded: { [speech] in speech }, engine: { whisperLike }, enabled: { true }) { shown.append($0) }
        other.start(at: 0, tick: nil)
        other.tick(at: 1)
        await other.pass?.value
        XCTAssertNil(other.pass)
        XCTAssertEqual(whisperLike.calls, [], "the alternative engine gets no partials")
    }

    /// Release, Esc or too short while a pass runs: its words never show.
    func testStopDropsThePassInFlight() async {
        var shown: [String] = []
        let live = LiveCaption(recorded: { [speech] in speech }, engine: { [self] in parakeet() }, enabled: { true }) { shown.append($0) }
        live.start(at: 0, tick: nil)
        live.tick(at: 1)
        live.stop()
        await live.pass?.value
        XCTAssertEqual(shown, [], "a partial that returns after the stop is dropped")
        XCTAssertEqual(live.shown, 0)
        live.tick(at: 5)
        XCTAssertEqual(heard.count, 1, "no pass after the stop")
    }

    /// The final pass waits for the engine, so a partial still on the model at the release would hold up the text by
    /// a whole pass. The release cancels it: the model gives up at its next step, and the final pass goes ahead.
    func testStopCancelsThePassOnTheModel() async throws {
        var entered = false, cancelled = false
        let slow = ParakeetEngine(recognize: { _ in
            entered = true
            do { try await Task.sleep(for: .seconds(2)) } catch { cancelled = true; throw error }  // a model step checks
            return ASRResult(text: "too late", confidence: 0.9, duration: 1, processingTime: 0, tokenTimings: [])
        }, dictionary: { Vocabulary("") })
        var shown: [String] = []
        let live = LiveCaption(recorded: { [speech] in speech }, engine: { slow }, enabled: { true }) { shown.append($0) }
        live.start(at: 0, tick: nil)
        live.tick(at: 1)
        for _ in 0..<100 where !entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(entered, "the partial is on the model")
        XCTAssertEqual(live.running, 1)
        let released = ProcessInfo.processInfo.systemUptime
        live.stop()
        await live.pass?.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - released, 1, "the release does not wait out the pass")
        XCTAssertTrue(cancelled, "the partial was cancelled, not left to finish")
        XCTAssertEqual(live.running, 0)
        XCTAssertEqual(shown, [])
    }

    /// A dictation can end without a stop (saving a too-short one failed): the recorder stopped, so live text does too.
    func testEndsWhenTheRecordingStopped() async {
        var recording = false
        let live = LiveCaption(recorded: { [speech] in recording ? speech : nil }, engine: { [self] in parakeet() },
                               enabled: { true }) { _ in }
        live.start(at: 0, tick: nil)
        live.tick(at: 1)
        recording = true
        live.tick(at: 2)
        await live.pass?.value
        XCTAssertEqual(heard, [], "stopped for good once the recording was gone")
    }

    func testSettingOffRunsNothing() async {
        let live = LiveCaption(recorded: { [speech] in speech }, engine: { [self] in parakeet() }, enabled: { false }) { _ in }
        live.start(at: 0, tick: nil)
        live.tick(at: 1)
        await live.pass?.value
        XCTAssertEqual(heard, [])
    }

    /// The app path: `start()` ticks on its own timer, and `stop()` ends it.
    func testTimerRunsPassesUntilStopped() async throws {
        var shown: [String] = []
        let live = LiveCaption(recorded: { [speech] in speech }, engine: { [self] in parakeet() }, enabled: { true }) { shown.append($0) }
        live.start(at: ProcessInfo.processInfo.systemUptime - 1, tick: 0.02)  // the first pass is due at once
        for _ in 0..<50 where shown.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(shown, ["only the end"])
        live.stop()
        let passes = heard.count
        try await Task.sleep(for: .milliseconds(1100))  // past the next pass's second
        XCTAssertEqual(heard.count, passes, "the timer is gone after the stop")
    }

    /// The snapshot copies; it never takes samples from the recording, so the final pass still gets all of them.
    func testSnapshotLeavesTheRecordingWhole() throws {
        let recorder = FedRecorder()
        XCTAssertNil(recorder.snapshot(last: 10), "nothing before a recording")
        recorder.start()
        recorder.feed(seconds: 2)
        let all = try XCTUnwrap(recorder.snapshot(last: .max))
        XCTAssertGreaterThan(all.count, AudioStore.sampleRate, "the samples so far")
        XCTAssertEqual(recorder.snapshot(last: 1000), Array(all.suffix(1000)), "the end of the recording so far")
        let final = recorder.stop()
        XCTAssertTrue(final.starts(with: all) && final.count >= all.count, "stop still returns every sample")
        XCTAssertNil(recorder.snapshot(last: 10), "nil once the recording stopped, so live text ends with it")
    }

    /// Rule 8: with partials shown during a 12 s dictation, the text Pipeline keeps is the final pass over the whole
    /// recording, never the last partial.
    func testTheFinalTextNeverComesFromAPartial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-live-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let recorder = FedRecorder()
        let engine = parakeet()
        var shown: [String] = []
        let live = LiveCaption(recorded: { recorder.snapshot(last: LiveText.windowSamples) }, engine: { engine },
                               enabled: { true }) { shown.append($0) }
        recorder.start()
        live.start(at: 0, tick: nil)
        for second in 1...12 {
            recorder.feed(seconds: 1)
            live.tick(at: Double(second))
            await live.pass?.value
        }
        live.stop()
        let samples = recorder.stop()
        let run = await pipeline.process(samples, engine: engine, context: { ("", "", "") }, focusKept: { false },
                                         sendPaste: { _ in XCTFail("no Cmd+V: focus moved") })
        XCTAssertEqual(shown.count, 12, "a partial each second")
        XCTAssertEqual(Set(shown), ["only the end"])
        XCTAssertEqual(run.entry.rawText, "every word from the start", "the final pass heard the whole recording")
        XCTAssertFalse(run.entry.text.contains("only the end"), run.entry.text)
        XCTAssertEqual(pasteboard.string(forType: .string)?.contains("only the end"), false)
    }
}

/// F13 in the indicator: the live words use creator mode's label (F114), so they sit right of 🤫, update in place,
/// and are gone with the dictation.
extension IndicatorTests {
    func testLiveWordsUpdateNextToTheIndicator() throws {
        let indicator = make()
        let corner = indicator.panel.frame.origin
        indicator.set(.recording)
        indicator.status = "send the report"
        XCTAssertEqual(indicator.labelText, "send the report")
        indicator.status = "…the report to the design team"
        XCTAssertEqual(indicator.labelText, "…the report to the design team", "each partial replaces the last")
        indicator.set(.handsFree)
        XCTAssertEqual(indicator.labelText, "…the report to the design team", "hands-free keeps them")
        let label = try XCTUnwrap(indicator.panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(indicator.panel.frame.origin, corner, "🤫 must not move as the words change")
        XCTAssertGreaterThanOrEqual(label.frame.minX, indicator.emoji.frame.maxX, "the words must not cover 🤫")
        indicator.set(.idle)  // Esc
        XCTAssertNil(indicator.labelText, "Esc clears the words")
    }

    /// Creator mode (F114) is for viewers to see the label the whole recording: live words come after it, never
    /// instead of it.
    func testLiveWordsKeepTheCreatorLabel() throws {
        let name = "shepetal-live-creator-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(Indicator.liveStatus("…the design team", defaults), "…the design team")
        defaults.set(true, forKey: Indicator.creatorModeKey)
        XCTAssertEqual(Indicator.liveStatus("…the design team", defaults), "Dictating with shepetal · …the design team")
    }

    /// A partial that comes back after the release must not show over "processing", an error, or idle.
    func testLiveWordsNeverShowOutsideARecording() {
        let indicator = make()
        for mode: Indicator.Mode in [.idle, .processing, .error] {
            indicator.set(mode)
            indicator.status = "late words"
            XCTAssertNil(indicator.status, "\(mode)")
            XCTAssertNil(indicator.labelText, "\(mode)")
            XCTAssertEqual(indicator.panel.frame, Indicator.frame(screen: mainScreen, labelWidth: nil), "\(mode)")
        }
        indicator.set(.error)
        indicator.show("Transcription failed", seconds: 0.05)
        indicator.status = "late words"
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(indicator.labelText, "nor after the error's hint ends")
    }
}
