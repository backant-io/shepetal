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
        try recorder.start()

        mic.checkHealth()
        XCTAssertEqual(recorder.opens, 2, "the silent start reopens the mic")
        XCTAssertEqual(ends.count, 1, "a failed reopen must end the dictation")
        XCTAssertEqual(ends.first?.0, true, "what was said before the failure is transcribed")
        XCTAssertEqual(ends.first?.1, "Mic: gone")
        XCTAssertFalse(recorder.isRecording)

        mic.checkHealth()
        XCTAssertEqual(ends.count, 1, "an ended dictation is not ended again")
    }
}
