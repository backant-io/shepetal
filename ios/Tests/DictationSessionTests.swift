import XCTest
@testable import ShepetalSessionCore

/// The app's dictation flow, driven with a fake mic and a fake model: the mic starts only for the
/// keyboard's request, every recording keeps the exact samples the model got, and the keyboard is
/// told how every session ended.
final class DictationSessionTests: XCTestCase {
    final class FakeMic: Microphone {
        var starts = 0
        var running = false
        var failStart = false
        func start() throws {
            if failStart { throw MicError() }
            starts += 1
            running = true
        }
        func stop() { running = false }
        var isRunning: Bool { running }
    }

    struct ModelError: LocalizedError { var errorDescription: String? { "model broke" } }
    struct MicError: Error {}

    let mic = FakeMic()
    let field = UUID()
    let speech = (0..<16_000).map { Float($0 % 100) / 100 } // 1 s at 16 kHz
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let handoffSuite = "shepetal-test-\(UUID().uuidString)", settingsSuite = "shepetal-test-\(UUID().uuidString)"
    var heard: [[Float]] = []
    var permissionAsks = 0

    var handoff: UserDefaults { UserDefaults(suiteName: handoffSuite)! }
    var state: Handoff { SharedHandoff.read(in: handoff) }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: handoffSuite)
        UserDefaults().removePersistentDomain(forName: settingsSuite)
    }

    @MainActor
    func makeSession(permission: Bool = true, model: Bool = true, modelFails: Bool = false) -> DictationSession {
        let session = DictationSession(mic: mic, directory: dir, handoff: handoff, settings: UserDefaults(suiteName: settingsSuite)!) {
            self.permissionAsks += 1
            await Task.yield() // the permission prompt is a suspension point
            return permission
        }
        if model {
            session.modelReady { samples in
                self.heard.append(samples)
                if modelFails { throw ModelError() }
                return "hello"
            }
        }
        return session
    }

    func url(_ id: UUID) -> URL { URL(string: "shepetal://dictate?id=\(id.uuidString)")! }

    func keyboardRequests(_ id: UUID) {
        SharedHandoff.update(in: handoff) { $0.request(id, document: field) }
    }

    /// The keyboard requests, the app opens the URL, the user speaks.
    @MainActor
    func recording(_ session: DictationSession, _ samples: [Float]? = nil) async -> UUID {
        let id = UUID()
        keyboardRequests(id)
        await session.open(url(id))
        XCTAssertTrue(session.isRecording)
        session.append(samples ?? speech)
        return id
    }

    func savedSamples(_ id: UUID) throws -> [Float] {
        let data = try Data(contentsOf: AudioArchive.url(for: id, in: dir))
        return stride(from: 44, to: data.count, by: 4).map { at in
            Float(bitPattern: data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
    }

    func entry(_ id: UUID) -> Recording? { AudioArchive.history(in: dir).first { $0.id == id } }

    // MARK: Any app can open shepetal://dictate; the mic starts only for the keyboard's request.

    @MainActor
    func testMicStaysOffForAURLTheKeyboardDidNotWrite() async {
        let session = makeSession()
        await session.open(url(UUID()))
        await session.open(URL(string: "shepetal://dictate")!)
        keyboardRequests(UUID())
        await session.open(url(UUID())) // a guessed id while a real request is pending
        XCTAssertEqual(mic.starts, 0)
        XCTAssertEqual(permissionAsks, 0) // not even the permission prompt
        XCTAssertFalse(session.isRecording)
        XCTAssertTrue(session.status.hasPrefix("Ignored"))
    }

    @MainActor
    func testOneKeyboardRequestStartsTheMicOnce() async {
        let session = makeSession()
        let id = UUID()
        keyboardRequests(id)
        await session.open(url(id))
        await session.open(url(id)) // replayed URL
        XCTAssertEqual(mic.starts, 1)
        XCTAssertEqual(state.phase, .recording)
    }

    @MainActor
    func testSameURLOpenedTwiceDuringThePermissionPromptRecordsOnce() async {
        let session = makeSession()
        let id = UUID()
        keyboardRequests(id)
        async let first: Void = session.open(url(id))
        async let second: Void = session.open(url(id))
        _ = await (first, second)
        XCTAssertEqual(mic.starts, 1)
        XCTAssertTrue(mic.running) // the second open must not stop the first recording
        XCTAssertTrue(session.isRecording)
    }

    @MainActor
    func testDeniedMicPermissionTellsTheKeyboard() async {
        let session = makeSession(permission: false)
        let id = UUID()
        keyboardRequests(id)
        await session.open(url(id))
        XCTAssertEqual(mic.starts, 0)
        XCTAssertEqual(state.keyboardStatus(for: id)?.hasPrefix("Microphone access is off"), true)
    }

    // MARK: Issue #14: any app can post the stop notification; only a stop the keyboard wrote ends the recording.

    @MainActor
    func testBareStopNotificationDoesNotStopTheRecording() async throws {
        let session = makeSession()
        session.observeKeyboard()
        let id = await recording(session)
        SharedHandoff.post(SharedHandoff.stopNotification) // what any other app can do
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(session.isRecording)
        XCTAssertTrue(mic.running)

        SharedHandoff.update(in: handoff) { _ = $0.requestStop(id) } // what the keyboard does first
        SharedHandoff.post(SharedHandoff.stopNotification)
        for _ in 0..<50 where session.isRecording { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(session.isRecording) // the same notification is delivered, and now it stops
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(try savedSamples(id), speech)
    }

    @MainActor
    func testStopRequestForAnotherSessionDoesNotStopTheRecording() async {
        let session = makeSession()
        _ = await recording(session)
        SharedHandoff.update(in: handoff) { _ = $0.requestStop(UUID()) }
        let ended = await session.followKeyboard()
        await session.tick()
        XCTAssertFalse(ended)
        XCTAssertTrue(session.isRecording)
    }

    @MainActor
    func testCancelForAnotherSessionDoesNotCancelTheRecording() async {
        let session = makeSession()
        let id = await recording(session)
        let other = UUID()
        keyboardRequests(other)
        SharedHandoff.update(in: handoff) { _ = $0.cancel(other) } // what the keyboard's cancel (#13) writes
        let ended = await session.followKeyboard()
        XCTAssertFalse(ended)
        XCTAssertTrue(session.isRecording)
        await session.tick() // superseded: kept and transcribed into history, not marked cancelled
        XCTAssertEqual(entry(id)?.outcome, .transcribed)
    }

    @MainActor
    func testStopRequestIsFollowedByTheTickWhenItsNotificationIsLost() async {
        let session = makeSession()
        let id = await recording(session)
        SharedHandoff.update(in: handoff) { _ = $0.requestStop(id) }
        await session.tick()
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(entry(id)?.outcome, .transcribed)
    }

    @MainActor
    func testCancelWrittenToTheSharedStateKeepsTheAudioMarkedCancelled() async throws {
        let session = makeSession()
        let id = await recording(session)
        SharedHandoff.update(in: handoff) { _ = $0.cancel(id) }
        let ended = await session.followKeyboard()
        XCTAssertTrue(ended)
        XCTAssertFalse(session.isRecording)
        XCTAssertTrue(heard.isEmpty)
        XCTAssertEqual(try savedSamples(id), speech)
        XCTAssertEqual(entry(id)?.outcome, .cancelled)
    }

    // MARK: Goal rule 3: the Live Activity shows 🤫 and the state while a dictation runs, and ends with it.

    @MainActor
    func testLiveActivityFollowsTheDictationAndEndsWhenTheTextIsDelivered() async {
        let session = makeSession()
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        _ = await recording(session)
        XCTAssertEqual(shown, [.recording])
        await session.stop()
        XCTAssertEqual(shown, [.recording, .processing, nil])
    }

    @MainActor
    func testLiveActivityShowsAFailureAndACancelEndsIt() async {
        let session = makeSession()
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        _ = await recording(session, Array(speech.prefix(DictationSession.minimumSamples - 1)))
        await session.stop()
        XCTAssertEqual(shown, [.recording, .error])
        _ = await recording(session)
        session.cancel()
        XCTAssertEqual(shown, [.recording, .error, .recording, nil])
    }

    @MainActor
    func testSupersededRecordingDoesNotEndTheNewRecordingsLiveActivity() async {
        let session = makeSession()
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        _ = await recording(session)
        let new = UUID()
        keyboardRequests(new)
        await session.open(url(new)) // the old recording is transcribed into history meanwhile
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(shown, [.recording])
    }

    @MainActor
    func testOlderRecordingFinishingLateDoesNotEndTheLiveActivityOfANewerOneThatStopped() async throws {
        let session = DictationSession(mic: mic, directory: dir, handoff: handoff, settings: UserDefaults(suiteName: settingsSuite)!) { true }
        let newer = Array(speech.reversed())
        session.modelReady { samples in
            // The superseded recording takes 0.3 s; the newer one takes 1.5 s, so the older finishes in between.
            try await Task.sleep(for: .milliseconds(samples == newer ? 1500 : 300))
            return samples == newer ? "newer" : "older"
        }
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        let old = await recording(session)
        let new = UUID()
        keyboardRequests(new)
        let opening = Task { await session.open(url(new)) } // ends the old recording, starts the new one, transcribes the old
        for _ in 0..<200 where state.sessionID != new || state.phase != .recording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isRecording)
        session.append(newer)
        let stopping = Task { await session.stop() } // the user stops the new one while the old is still transcribing
        await opening.value
        XCTAssertEqual(entry(old)?.text, "older")
        XCTAssertEqual(session.activity, .processing) // still "Transcribing" for the new recording
        XCTAssertEqual(session.status, "Transcribing...")
        await stopping.value
        XCTAssertNil(session.activity)
        XCTAssertEqual(shown, [.recording, .processing, nil])
        var h = state
        XCTAssertEqual(h.consume(new, document: field), "newer")
    }

    @MainActor
    func testMicThatFailsToStartForANewRequestEndsTheLiveActivityAndTranscribesTheOldRecording() async {
        let session = makeSession()
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        let old = await recording(session)
        mic.failStart = true
        let new = UUID()
        keyboardRequests(new)
        await session.open(url(new))
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(mic.running)
        XCTAssertEqual(shown.last, .error) // not stuck on "Listening" while nothing records
        XCTAssertEqual(entry(old)?.outcome, .transcribed)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(session.status.hasPrefix("Could not start recording"))
    }

    // MARK: Product rule 4: every recording keeps the exact samples the model got, next to its history entry.

    @MainActor
    func testStoppedRecordingKeepsTheSamplesTheModelGotAndDeliversTheText() async throws {
        let session = makeSession()
        let id = await recording(session)
        await session.stop()
        XCTAssertFalse(mic.running)
        XCTAssertEqual(heard, [speech])
        XCTAssertEqual(try savedSamples(id), speech)
        XCTAssertEqual(entry(id)?.outcome, .transcribed)
        XCTAssertEqual(entry(id)?.text, "hello")
        XCTAssertEqual(entry(id)?.audio, AudioArchive.url(for: id, in: dir).lastPathComponent)
        var h = state
        XCTAssertEqual(h.consume(id, document: field), "hello")
    }

    @MainActor
    func testCancelledRecordingKeepsItsAudioMarkedCancelled() async throws {
        let session = makeSession()
        let id = await recording(session)
        session.cancel()
        XCTAssertFalse(mic.running)
        XCTAssertTrue(heard.isEmpty)
        XCTAssertEqual(try savedSamples(id), speech)
        XCTAssertEqual(entry(id)?.outcome, .cancelled)
        XCTAssertEqual(state.phase, .cancelled)
    }

    @MainActor
    func testRecordingStopsAtTheFiveMinuteCapAndIsKeptAndDelivered() async throws {
        let session = makeSession()
        let id = await recording(session)
        await session.tick(now: Date().addingTimeInterval(Handoff.maxRecording - 1))
        XCTAssertTrue(session.isRecording)
        await session.tick(now: Date().addingTimeInterval(Handoff.maxRecording))
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(mic.running)
        XCTAssertEqual(try savedSamples(id), speech)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.message, "Stopped at the 5-minute limit.")
    }

    @MainActor
    func testSupersededRecordingIsKeptAndTranscribedIntoHistoryButNotDelivered() async throws {
        let session = makeSession()
        let old = await recording(session)
        let new = UUID()
        keyboardRequests(new) // the keyboard started over
        await session.tick()
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(try savedSamples(old), speech)
        XCTAssertEqual(entry(old)?.text, "hello") // late text goes to history
        XCTAssertEqual(state.sessionID, new)
        XCTAssertEqual(state.phase, .requested)
        XCTAssertNil(state.text)
    }

    @MainActor
    func testNewRequestWhileRecordingKeepsTheOldAudioAndRecordsTheNewOne() async throws {
        let session = makeSession()
        let old = await recording(session)
        let new = UUID()
        keyboardRequests(new)
        await session.open(url(new))
        XCTAssertEqual(try savedSamples(old), speech)
        XCTAssertEqual(mic.starts, 2)
        XCTAssertTrue(mic.running)
        XCTAssertEqual(state.sessionID, new)
        XCTAssertEqual(state.phase, .recording)
    }

    // MARK: The keyboard is told how a dictation ended, instead of showing "Transcribing..." until it expires.

    @MainActor
    func testTooShortRecordingIsKeptMarkedAndTheKeyboardIsTold() async throws {
        let session = makeSession()
        let short = Array(speech.prefix(DictationSession.minimumSamples - 1))
        let id = await recording(session, short)
        await session.stop()
        XCTAssertTrue(heard.isEmpty) // the model rejects audio under 0.3 s
        XCTAssertEqual(try savedSamples(id), short)
        XCTAssertEqual(entry(id)?.outcome, .tooShort)
        XCTAssertEqual(state.keyboardStatus(for: id)?.hasPrefix("Too short"), true)
    }

    @MainActor
    func testModelNotLoadedYetTellsTheKeyboardAndKeepsTheAudio() async throws {
        let session = makeSession(model: false)
        let id = await recording(session)
        await session.stop()
        XCTAssertEqual(try savedSamples(id), speech)
        XCTAssertEqual(entry(id)?.outcome, .failed)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.keyboardStatus(for: id)?.contains("still loading"), true)
    }

    @MainActor
    func testTranscriptionErrorTellsTheKeyboardAndKeepsTheAudio() async throws {
        let session = makeSession(modelFails: true)
        let id = await recording(session)
        await session.stop()
        XCTAssertEqual(try savedSamples(id), speech)
        XCTAssertEqual(entry(id)?.outcome, .failed)
        XCTAssertEqual(state.keyboardStatus(for: id)?.contains("model broke"), true)
    }

    // MARK: A call, Siri or a route change stops AVAudioEngine; the recording must not go on with a dead mic.

    @MainActor
    func testMicThatDiesMidRecordingEndsTheRecordingAndSaysWhy() async throws {
        let session = makeSession()
        let id = await recording(session)
        mic.running = false // the system stopped the engine
        await session.tick()
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(try savedSamples(id), speech)
        var h = state
        XCTAssertEqual(h.consume(id, document: field), "hello")
        XCTAssertEqual(h.keyboardStatus(for: id)?.hasPrefix("Recording stopped early"), true)
        XCTAssertEqual(entry(id)?.note?.hasPrefix("Recording stopped early"), true)
    }

    // MARK: Audio that cannot be written yet (iPhone locked) is kept in memory, shown, and saved later.

    @MainActor
    func testAudioThatCannotBeWrittenYetIsKeptShownAndSavedLater() async throws {
        try Data().write(to: dir) // a file where the directory goes: every write fails, like a locked iPhone
        let session = makeSession()
        let first = await recording(session)
        await session.stop()
        let second = await recording(session, Array(speech.reversed())) // the next dictation must not drop the first
        await session.stop()
        XCTAssertEqual(session.status, DictationSession.ready)
        XCTAssertNotNil(session.saveError) // not overwritten by the status that followed
        try FileManager.default.removeItem(at: dir) // unlocked
        session.flush()
        XCTAssertNil(session.saveError)
        XCTAssertEqual(try savedSamples(first), speech)
        XCTAssertEqual(try savedSamples(second), Array(speech.reversed()))
        XCTAssertEqual(entry(first)?.text, "hello")
    }

    // MARK: Retention: keep (the default) or delete after 24 h.

    @MainActor
    func testRecordingsAreKeptByDefaultAndDeletedAfter24hWhenChosen() async throws {
        let session = makeSession()
        XCTAssertFalse(session.deleteAfter24h)
        let id = await recording(session)
        await session.stop()
        let audio = AudioArchive.url(for: id, in: dir).path
        let dayLater = Date().addingTimeInterval(DictationSession.retention + 1)
        session.sweep(now: dayLater)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio))
        session.deleteAfter24h = true
        session.sweep(now: Date().addingTimeInterval(DictationSession.retention - 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio))
        session.sweep(now: dayLater)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio))
        XCTAssertNil(entry(id))
        XCTAssertFalse(session.history.contains { $0.id == id })
        XCTAssertTrue(makeSession().deleteAfter24h) // the choice is remembered
    }

    // MARK: Product rule 8.

    func testDonateLinksPointToBothPages() {
        XCTAssertEqual(Donate.coffee.absoluteString, "https://buymeacoffee.com/sorcecoder")
        XCTAssertEqual(Donate.sponsors.absoluteString, "https://github.com/sponsors/backant-io")
    }
}
