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
    /// Every card change: the app it shows, nil when it hides.
    private var cards: [String?] = []
    private var autoRecord = false

    private let zoom = Snapshot(micUsers: [MicUser(pid: 100, bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us")])
    private let quiet = Snapshot()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-recorder-\(UUID().uuidString)")
        capture = FakeCapture()
        hints = []
        ended = []
        cards = []
        autoRecord = false
        recorder = MeetingRecorder(dir: root, capture: capture, detector: MeetingDetector(ownPID: getpid()),
                                   autoRecord: { [unowned self] in autoRecord }, card: { [unowned self] in cards.append($0) }) { [unowned self] in hints.append($0) }
        recorder.onEnded = { [unowned self] in ended.append($0) }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// One snapshot per second from `from` up to and including `to`, like the 1 s poll.
    private func feed(_ s: Snapshot, _ from: Int, _ to: Int) {
        for t in from...to { recorder.update(s, now: Double(t)) }
    }

    func testDetectedMeetingIsOfferedAndRecordsBothChannelsOwnerOnlyOnceRecordIsClicked() throws {
        feed(zoom, 0, 4)
        XCTAssertEqual(cards, [], "the 5 s start grace must pass first")
        feed(zoom, 5, 5)
        XCTAssertEqual(cards, ["zoom.us"], "Meeting detected · zoom.us")
        XCTAssertNil(recorder.current, "detected is not consent: nothing records before the click")
        XCTAssertTrue(capture.started.isEmpty)
        XCTAssertEqual(hints, [])
        feed(zoom, 6, 10)
        XCTAssertTrue(capture.started.isEmpty, "still waiting for the click")

        recorder.record()
        XCTAssertEqual(cards, ["zoom.us", nil], "the card goes once Record is clicked")
        let meeting = try XCTUnwrap(recorder.current)
        XCTAssertEqual(meeting.app, "zoom.us")
        XCTAssertNil(meeting.endedAt, "running")
        XCTAssertEqual(hints, ["Meeting detected · recording"])

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
    }

    func testWithoutSystemAudioOnlyTheMicIsRecordedAndTheHintSaysSo() throws {
        capture.systemAudio = false
        feed(zoom, 0, 5)
        recorder.record()
        XCTAssertEqual(hints, ["Meeting detected · recording mic only (turn on System Audio Recording)"])
        XCTAssertEqual(recorder.current?.othersAudioPath, "", "no Others channel to transcribe")
        recorder.stop()
        XCTAssertEqual(ended.first?.othersAudioPath, "")
        XCTAssertFalse(ended.first?.meAudioPath.isEmpty ?? true, "the mic channel is still handed over")
    }

    func testStoppedByHandIsNotRestartedUntilThatMeetingEndsAndANewOneStarts() {
        feed(zoom, 0, 5)
        recorder.record()
        recorder.stop()
        XCTAssertEqual(ended.count, 1)
        feed(zoom, 6, 60)
        XCTAssertNil(recorder.current, "the same call must not start recording again")
        XCTAssertEqual(capture.started.count, 1)

        feed(quiet, 61, 70)
        feed(zoom, 71, 76)
        XCTAssertEqual(cards.last, "zoom.us", "the next call is offered again")
        recorder.record()
        XCTAssertNotNil(recorder.current)
        XCTAssertEqual(capture.started.count, 2)
    }

    func testNotNowRecordsNothingForThatMeetingAndTheNextOneIsOfferedAgain() {
        feed(zoom, 0, 5)
        recorder.notNow()
        XCTAssertEqual(cards, ["zoom.us", nil])
        recorder.record()  // a late click on a card that is gone
        feed(zoom, 6, 120)
        XCTAssertNil(recorder.current)
        XCTAssertTrue(capture.started.isEmpty, "Not now starts nothing for that meeting")
        XCTAssertEqual(cards, ["zoom.us", nil], "and does not ask again during it")

        feed(quiet, 121, 130)
        feed(zoom, 131, 136)
        XCTAssertEqual(cards, ["zoom.us", nil, "zoom.us"], "a new meeting is a new question")
        XCTAssertTrue(capture.started.isEmpty)
    }

    func testCardDismissesItselfAfter20sAndRecordsNothing() {
        feed(zoom, 0, 5)  // offered at 5 s
        feed(zoom, 6, 24)
        XCTAssertEqual(cards, ["zoom.us"], "up for the whole 20 s")
        feed(zoom, 25, 25)
        XCTAssertEqual(cards, ["zoom.us", nil], "gone at 20 s")
        recorder.record()
        feed(zoom, 26, 120)
        XCTAssertTrue(capture.started.isEmpty, "the timeout starts nothing for that meeting")
        XCTAssertEqual(hints, [])
    }

    func testMeetingThatEndsWhileOfferedTakesTheCardAway() {
        feed(zoom, 0, 5)
        feed(quiet, 6, 22)  // Zoom let go of the mic: the meeting ends at 20 s (15 s minimum), before the timeout
        XCTAssertEqual(cards, ["zoom.us", nil])
        recorder.record()
        XCTAssertTrue(capture.started.isEmpty, "a meeting that is over is not recorded")
    }

    func testAlwaysRecordSettingStartsAtOnceWithTheHintAndStop() throws {
        autoRecord = true
        feed(zoom, 0, 5)
        XCTAssertEqual(try XCTUnwrap(recorder.current).app, "zoom.us")
        XCTAssertEqual(capture.started.count, 1)
        XCTAssertEqual(hints, ["Meeting detected · recording"])
        XCTAssertFalse(cards.contains { $0 != nil }, "no question when the setting says always")
    }

    /// The consent rule as a property: with the setting off and no click on Record, an hour of calls coming and
    /// going (with Not now, timeouts and late clicks on gone cards in between) never opens the mic or the tap.
    func testCaptureNeverStartsWithoutAClickWhileTheSettingIsOff() {
        var seed: UInt64 = 42
        var t = 0
        while t < 3600 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let length = 1 + Int(seed >> 33) % 90
            feed(seed & 1 == 0 ? zoom : quiet, t, t + length)
            if seed & 6 == 2 { recorder.notNow() }
            t += length + 1
        }
        XCTAssertGreaterThan(cards.compactMap { $0 }.count, 5, "the run must offer meetings, or it proves nothing")
        XCTAssertTrue(capture.started.isEmpty, "capture started without a click")
        XCTAssertNil(recorder.current)
        XCTAssertEqual(hints, [])
    }

    /// Unset in Settings means off: the app's default reading of the setting only offers.
    func testSettingIsOffByDefault() throws {
        let name = "shepetal-auto-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(MeetingRecorder.autoRecords(defaults))
        defaults.set(true, forKey: MeetingRecorder.autoRecordKey)
        XCTAssertTrue(MeetingRecorder.autoRecords(defaults))

        try XCTSkipIf(UserDefaults.standard.object(forKey: MeetingRecorder.autoRecordKey) != nil, "set in this test runner's defaults")
        let plain = MeetingRecorder(dir: root, capture: capture, detector: MeetingDetector(ownPID: getpid()),
                                    card: { [unowned self] in cards.append($0) }) { [unowned self] in hints.append($0) }
        for t in 0...5 { plain.update(zoom, now: Double(t)) }
        XCTAssertEqual(cards, ["zoom.us"])
        XCTAssertTrue(capture.started.isEmpty)
    }

    func testStartingByHandAnswersTheCard() {
        feed(zoom, 0, 5)
        recorder.toggle()
        XCTAssertEqual(cards, ["zoom.us", nil])
        XCTAssertEqual(recorder.current?.app, MeetingRecorder.manualApp, "the menu's Record meeting keeps working")
        XCTAssertEqual(hints, ["Recording meeting"])
        recorder.toggle()
        XCTAssertNil(recorder.current)
        XCTAssertEqual(ended.map(\.app), [MeetingRecorder.manualApp])
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
        recorder.record()
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
        defaults.set(60, forKey: "meeting.endAfter")
        let d = MeetingRecorder.configuredDetector(defaults)
        XCTAssertEqual(d.startAfter, 2)
        XCTAssertEqual(d.endAfter, 60)
        XCTAssertEqual(d.minSession, MeetingDetector(ownPID: 0).minSession, "unset keys keep the defaults")
    }

    /// The app's own dictation and meeting capture run in this process: its detector must never offer them.
    func testTheAppsDetectorIgnoresItsOwnMicUse() {
        let d = MeetingRecorder.configuredDetector()
        let me = MicUser(pid: ProcessInfo.processInfo.processIdentifier, path: "/Applications/Shepetal.app/Contents/MacOS/Shepetal")
        XCTAssertNil(d.app(in: Snapshot(micUsers: [me])))
        XCTAssertEqual(d.app(in: zoom), "zoom.us")
    }

    /// "Not now" holds while the camera stays on after the mic goes: it is the same meeting until both are free.
    func testNotNowHoldsUntilMicAndCameraAreBothReleased() {
        let camera = Snapshot(cameraInUse: true)
        feed(Snapshot(micUsers: zoom.micUsers, cameraInUse: true), 0, 5)
        recorder.notNow()
        feed(camera, 6, 120)  // mic muted, video still on
        XCTAssertEqual(cards, ["zoom.us", nil], "no new card while the camera runs")
        feed(quiet, 121, 125)
        feed(camera, 126, 131)
        XCTAssertEqual(cards, ["zoom.us", nil, "Camera"], "used again after both were free: a new question")
        XCTAssertTrue(capture.started.isEmpty)
    }
}

private extension NSMenuItem {
    /// What a click on the item does.
    func performAction() { _ = (target as? NSObject)?.perform(action) }
}
