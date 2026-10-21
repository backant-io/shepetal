import ShepetalCore
import XCTest
@testable import Shepetal

/// A recorder whose hardware open works once, then fails, like a mic that goes away while it is reopened.
final class FlakyRecorder: Recorder {
    var opens = 0
    override func open(_ device: MicDevice?) throws {
        opens += 1
        if opens > 1 { throw SpeechError("gone") }
    }
    override func healthEvents() -> [MicHealth.Event] { [.reopen] }
}

/// A mic that never opens.
final class DeadRecorder: Recorder {
    override func open(_ device: MicDevice?) throws { throw SpeechError("gone") }
}

/// AVAudioEngine after `open` moved it to a mic that is not its default: right after the start it posts one
/// configuration change, `running` or stopped by itself, and every new engine does the same (Pavel's 21.10.26
/// retest, unified log "iounit configuration changed"). `newFormat` is a Bluetooth headset that switches its
/// profile once, on the first open.
final class MovedEngineRecorder: Recorder {
    var opens = 0, restarts = 0
    var running = false, newFormat = false, changesAfterRestart = false
    var opened: XCTestExpectation?
    override func open(_ device: MicDevice?) throws {
        opens += 1
        engineChanged(running: running, formatKept: !(newFormat && opens == 1))
        if opens == 1 { opened?.fulfill() }
    }
    override func restart() throws {
        restarts += 1
        if changesAfterRestart { engineChanged(running: false, formatKept: true) }
    }
}

/// A mic whose buffers stopped partway.
final class StalledRecorder: Recorder {
    override func open(_ device: MicDevice?) throws {}
    override func healthEvents() -> [MicHealth.Event] { [.stalled] }
}

/// A reopen closes the engine before it opens it again. When that open fails, the dictation must still end
/// with a message (the audio so far is transcribed and kept). Otherwise the ring keeps showing recording,
/// hands-free included, while nothing is captured.
@MainActor
final class RecorderTests: XCTestCase {
    func testFailedReopenEndsTheDictationOnce() throws {
        let recorder = FlakyRecorder()
        let mic = Mic(recorder: recorder)
        var ends: [(Bool, String)] = []
        // Like App: ending the dictation stops the mic.
        mic.end = { ends.append(($0, $1)); _ = mic.stop() }
        recorder.start()

        mic.checkHealth()
        XCTAssertEqual(recorder.opens, 2, "the silent start reopens the mic")
        XCTAssertEqual(ends.count, 1, "a failed reopen must end the dictation")
        XCTAssertEqual(ends.first?.0, true, "what was said before the failure is transcribed")
        XCTAssertEqual(ends.first?.1, "Mic: gone")
        XCTAssertFalse(recorder.isRecording)

        mic.checkHealth()
        XCTAssertEqual(ends.count, 1, "an ended dictation is not ended again")
    }

    /// Buffers that stop partway end the dictation with a message, and what came before is transcribed.
    func testStalledMicEndsTheDictationAndKeepsTheAudio() {
        let recorder = StalledRecorder()
        let mic = Mic(recorder: recorder)
        var ends: [(Bool, String)] = []
        mic.end = { ends.append(($0, $1)); _ = mic.stop() }
        recorder.start(MicDevice(uid: "usb-1", name: "desk mic", transport: .usb))
        mic.checkHealth()
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(ends.first?.0, true, "what was said before the stall is transcribed")
        XCTAssertEqual(ends.first?.1, "Desk mic stopped sending audio")
    }

    /// The mic opens off the main thread, after the recording has started. When that open fails, the dictation
    /// ends right away with nothing to transcribe, instead of showing recording on a closed mic until fn is up.
    func testFailedOpenEndsTheDictation() {
        let recorder = DeadRecorder()
        let mic = Mic(recorder: recorder)
        let ended = expectation(description: "the dictation ends")
        mic.end = { transcribe, message in
            XCTAssertFalse(transcribe, "nothing was recorded")
            XCTAssertEqual(message, "Microphone: gone")
            _ = mic.stop()
            ended.fulfill()
        }
        recorder.start()
        wait(for: [ended], timeout: 5)
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: the engine's own configuration change (21.10.26: every dictation was empty)

    private let mic = MicDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)

    /// Starts a dictation and lets it settle: the first open runs on the mic queue, each rebuild after it is one
    /// turn of the main queue. Returns how the mic ended the dictation, if it did.
    private func dictate(_ recorder: MovedEngineRecorder) -> [(Bool, String)] {
        let mic = Mic(recorder: recorder, inputs: { [self] in [self.mic] })
        var ends: [(Bool, String)] = []
        mic.end = { ends.append(($0, $1)); _ = mic.stop() }
        recorder.opened = expectation(description: "the mic opens")
        recorder.start(self.mic)
        wait(for: [recorder.opened!], timeout: 5)
        for _ in 0..<6 {
            let turn = expectation(description: "main queue turn")
            DispatchQueue.main.async { turn.fulfill() }
            wait(for: [turn], timeout: 5)
        }
        return ends
    }

    /// The root cause of the empty recordings: a new engine for the engine's own change moved again and changed
    /// again, until the rebuilds ran out with no buffer. The engine already sits on the mic: start it again.
    func testEngineThatStoppedAfterTheMoveStartsAgainInsteadOfARebuild() {
        let recorder = MovedEngineRecorder()
        let ends = dictate(recorder)
        XCTAssertEqual(recorder.opens, 1, "a new engine would move and change again")
        XCTAssertEqual(recorder.restarts, 1)
        XCTAssertTrue(ends.isEmpty, "the dictation keeps recording, got \(ends)")
        XCTAssertTrue(recorder.isRecording)
    }

    func testEngineStillRunningAfterTheMoveIsLeftAlone() {
        let recorder = MovedEngineRecorder()
        recorder.running = true
        let ends = dictate(recorder)
        XCTAssertEqual(recorder.opens, 1)
        XCTAssertEqual(recorder.restarts, 0, "it is still delivering buffers")
        XCTAssertTrue(ends.isEmpty, "got \(ends)")
    }

    /// A real format change still gets a new engine, which reads the new format; restarting the old one would
    /// keep the stale tap.
    func testNewFormatStillBuildsANewEngine() {
        let recorder = MovedEngineRecorder()
        recorder.newFormat = true
        let ends = dictate(recorder)
        XCTAssertEqual(recorder.opens, 2, "the old engine has the old format")
        XCTAssertEqual(recorder.restarts, 1, "only the new engine's own change after its move")
        XCTAssertTrue(ends.isEmpty, "got \(ends)")
    }

    /// An engine that changes again after every restart must not restart forever: after the restarts come the
    /// rebuilds, and after those the dictation ends with what it has.
    func testEngineThatKeepsChangingEndsTheDictation() {
        let recorder = MovedEngineRecorder()
        recorder.changesAfterRestart = true
        let ends = dictate(recorder)
        XCTAssertEqual(recorder.restarts, 3)
        XCTAssertEqual(recorder.opens, 4, "the first engine and three rebuilds")
        XCTAssertEqual(ends.count, 1, "got \(ends)")
        XCTAssertEqual(ends.first?.0, true)
        XCTAssertEqual(ends.first?.1, "Mic stopped: MacBook Pro Microphone keeps changing its format")
    }
}
