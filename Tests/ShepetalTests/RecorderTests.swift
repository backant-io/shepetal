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
}
