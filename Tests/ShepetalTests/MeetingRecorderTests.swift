import XCTest
import MeetingCore
import ShepetalCore
@testable import Shepetal

/// The detector-to-recorder state machine with a scripted probe and a fake capture: no mic, no system
/// audio, no TCC. The real Core Audio capture is a hand test.
@MainActor
final class MeetingRecorderTests: XCTestCase {
    private final class FakeCapture: MeetingCapturing {
        var systemAudio = true
        var writes = true
        var failStart: Error?
        var started: [URL] = []
        var stops = 0

        func start(dir: URL) throws -> Bool {
            if let failStart { throw failStart }
            started.append(dir)
            if writes {
                FileManager.default.createFile(atPath: dir.appendingPathComponent("Me.wav").path, contents: Data([1]))
                if systemAudio {
                    FileManager.default.createFile(atPath: dir.appendingPathComponent("Others.wav").path, contents: Data([1]))
                }
            }
            return systemAudio
        }

        func stop() throws { stops += 1 }
    }

    private var root: URL!
    private var capture: FakeCapture!
    private var recorder: MeetingRecorder!
    private var hints: [String] = []
    private var ended: [Meeting] = []

    private let zoom = Snapshot(micClients: [MicClient(bundleID: "us.zoom.xos", name: "zoom.us")])
    private let quiet = Snapshot()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-recorder-\(UUID().uuidString)")
        capture = FakeCapture()
        hints = []
        ended = []
        recorder = MeetingRecorder(dir: root, capture: capture, detector: MeetingDetector()) { [unowned self] in hints.append($0) }
        recorder.onEnded = { [unowned self] in ended.append($0) }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// One snapshot per second from `from` up to and including `to`, like the 1 s poll.
    private func feed(_ s: Snapshot, _ from: Int, _ to: Int) {
        for t in from...to { recorder.update(s, now: Double(t)) }
    }

    func testDetectedMeetingRecordsBothChannelsOwnerOnlyAndHandsThemToTheTranscriber() throws {
        feed(zoom, 0, 4)
        XCTAssertNil(recorder.current, "the 5 s start grace must pass first")
        feed(zoom, 5, 5)
        let meeting = try XCTUnwrap(recorder.current)
        XCTAssertEqual(meeting.app, "Zoom")
        XCTAssertNil(meeting.endedAt, "running")
        XCTAssertEqual(hints, ["Meeting detected · recording"])
        XCTAssertEqual(recorder.menuItem.title, "Stop meeting recording")

        let folder = try XCTUnwrap(capture.started.first)
        XCTAssertEqual(folder.path, root.appendingPathComponent(meeting.id).path, "one folder per meeting under meetings/")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700, "meeting audio lives in an owner-only folder (rule 4)")
        XCTAssertEqual(meeting.meAudioPath, folder.appendingPathComponent("Me.wav").path)
        XCTAssertEqual(meeting.othersAudioPath, folder.appendingPathComponent("Others.wav").path)

        feed(zoom, 6, 30)
        XCTAssertTrue(ended.isEmpty, "still in the call")
        feed(quiet, 31, 40)  // Zoom let go of the mic: a native release ends it within seconds
        XCTAssertNil(recorder.current)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.id, meeting.id)
        XCTAssertNotNil(ended.first?.endedAt)
        XCTAssertEqual(ended.first?.meAudioPath, meeting.meAudioPath, "both channels go to the transcriber")
        XCTAssertEqual(ended.first?.othersAudioPath, meeting.othersAudioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.meAudioPath), "the audio is kept")
        XCTAssertEqual(recorder.menuItem.title, "Start meeting recording")
    }

    func testWithoutSystemAudioOnlyTheMicIsRecordedAndTheHintSaysSo() throws {
        capture.systemAudio = false
        feed(zoom, 0, 5)
        XCTAssertEqual(hints, ["Meeting detected · recording mic only (turn on System Audio Recording)"])
        XCTAssertEqual(recorder.current?.othersAudioPath, "", "no Others channel to transcribe")
        recorder.stop()
        XCTAssertEqual(ended.first?.othersAudioPath, "")
        XCTAssertFalse(ended.first?.meAudioPath.isEmpty ?? true, "the mic channel is still handed over")
    }

    func testStoppedByHandIsNotRestartedUntilThatMeetingEndsAndANewOneStarts() {
        feed(zoom, 0, 5)
        recorder.stop()
        XCTAssertEqual(ended.count, 1)
        feed(zoom, 6, 60)
        XCTAssertNil(recorder.current, "the same call must not start recording again")
        XCTAssertEqual(capture.started.count, 1)

        feed(quiet, 61, 70)
        feed(zoom, 71, 76)
        XCTAssertNotNil(recorder.current, "the next call is recorded again")
        XCTAssertEqual(capture.started.count, 2)
    }

    func testManualRecordingRunsUntilStoppedByHand() {
        recorder.start()
        XCTAssertEqual(recorder.current?.app, MeetingRecorder.manualApp)
        XCTAssertEqual(hints, ["Recording meeting"])
        feed(zoom, 0, 20)
        feed(quiet, 21, 60)  // a detected meeting ending must not stop a manual recording
        XCTAssertNotNil(recorder.current)
        XCTAssertEqual(capture.started.count, 1, "a detected start does not open a second recording")
        recorder.stop()
        XCTAssertEqual(ended.map(\.app), [MeetingRecorder.manualApp])
    }

    func testCaptureThatCannotStartRecordsNothing() {
        capture.failStart = SpeechError("Microphone access is off")
        feed(zoom, 0, 5)
        XCTAssertNil(recorder.current)
        XCTAssertEqual(hints, ["Meeting recording failed: Microphone access is off"])
        feed(quiet, 6, 40)
        XCTAssertTrue(ended.isEmpty)
        XCTAssertEqual(capture.stops, 0)
    }

    func testNoAudioWrittenIsNotHandedOver() {
        capture.writes = false
        recorder.start()
        recorder.stop()
        XCTAssertTrue(ended.isEmpty, "nothing to transcribe")
        XCTAssertEqual(hints.last, "Meeting not saved: no audio was captured")
    }

    func testThresholdsAreConfigurable() throws {
        let name = "shepetal-recorder-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2.0, forKey: "meeting.startAfter")
        defaults.set(60, forKey: "meeting.endWithoutEvidence")
        let d = MeetingRecorder.configuredDetector(defaults)
        XCTAssertEqual(d.startAfter, 2)
        XCTAssertEqual(d.endWithoutEvidence, 60)
        XCTAssertEqual(d.minSession, MeetingDetector().minSession, "unset keys keep the defaults")
    }
}
