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
        var capturing = false
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
    /// Most tests close the mic after each dictation, the flow before the mic stayed open; the open-mic
    /// tests pass `keepOpen`.
    func makeSession(permission: Bool = true, model: Bool = true, modelFails: Bool = false, keepOpen: KeepOpen = .afterEach) -> DictationSession {
        let session = DictationSession(mic: mic, directory: dir, handoff: handoff, settings: UserDefaults(suiteName: settingsSuite)!) {
            self.permissionAsks += 1
            await Task.yield() // the permission prompt is a suspension point
            return permission
        }
        session.keepOpen = keepOpen
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

        SharedHandoff.requestStop(id, in: handoff) // what the keyboard does first
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
        handoff.set(UUID().uuidString, forKey: "stopRequest") // an older session's stop, still in the key
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
        SharedHandoff.requestStop(id, in: handoff)
        await session.tick()
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(entry(id)?.outcome, .transcribed)
    }

    // MARK: Issue #63: the keyboard's stop and the app ending the recording itself never write the same record.

    @MainActor
    func testStopTapInTheSameInstantAsTheCapStillDeliversTheText() async {
        let session = makeSession()
        let id = await recording(session)
        // The keyboard checked the state while it was still recording...
        XCTAssertTrue(state.canStop(id))
        await session.stop(reason: "Stopped at the 5-minute limit.") // ...the app hits the cap and delivers...
        XCTAssertEqual(state.phase, .ready)
        handoff.set(id.uuidString, forKey: "stopRequest") // ...then the keyboard's stop write lands.
        XCTAssertEqual(state.phase, .ready) // the late write cannot put back `recording`
        let ended = await session.followKeyboard()
        XCTAssertFalse(ended)
        var copy = state
        XCTAssertEqual(copy.consume(id, document: field), .insert("hello"))
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
        XCTAssertEqual(shown, [.recording, .recording]) // sent again for the new recording, never ended
    }

    /// Holds a fake transcription until the test releases it, so the order of events does not depend on timing.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen { lock.unlock(); continuation.resume() } else { waiter = continuation; lock.unlock() }
            }
        }
        func release() {
            lock.lock()
            isOpen = true
            let waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    @MainActor
    func testOlderRecordingFinishingLateDoesNotEndTheLiveActivityOfANewerOneThatStopped() async throws {
        let session = DictationSession(mic: mic, directory: dir, handoff: handoff, settings: UserDefaults(suiteName: settingsSuite)!) { true }
        session.keepOpen = .afterEach
        let newer = Array(speech.reversed())
        let olderDone = Gate(), newerDone = Gate()
        session.modelReady { samples in
            await (samples == newer ? newerDone : olderDone).wait()
            return samples == newer ? "newer" : "older"
        }
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        let old = await recording(session)
        let new = UUID()
        keyboardRequests(new)
        let opening = Task { await session.open(url(new)) } // ends the old recording, starts the new one, transcribes the old
        for _ in 0..<500 where state.sessionID != new || state.phase != .recording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isRecording)
        session.append(newer)
        let stopping = Task { await session.stop() } // the user stops the new one while the old is still transcribing
        for _ in 0..<500 where session.activity != .processing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.activity, .processing)
        olderDone.release() // the old transcription finishes while the new one is still transcribing
        await opening.value
        XCTAssertEqual(entry(old)?.text, "older")
        XCTAssertEqual(session.activity, .processing) // still "Transcribing" for the new recording
        XCTAssertEqual(session.status, "Transcribing...")
        newerDone.release()
        await stopping.value
        XCTAssertNil(session.activity)
        XCTAssertEqual(shown, [.recording, .recording, .processing, nil])
        var h = state
        XCTAssertEqual(h.consume(new, document: field), .insert("newer"))
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
        XCTAssertEqual(shown, [.recording, .error]) // not stuck on "Listening", and not ended before the error shows
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
        XCTAssertEqual(h.consume(id, document: field), .insert("hello"))
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
        XCTAssertEqual(h.consume(id, document: field), .insert("hello"))
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

    // MARK: The mic stays open after a dictation, so the next one starts from the keyboard without the app.

    @MainActor
    func testOpenMicStartsTheNextDictationFromTheKeyboardAndKeepsOnlyItsOwnFrames() async throws {
        let session = makeSession(keepOpen: .fiveMinutes)
        let first = await recording(session)
        await session.stop()
        XCTAssertTrue(mic.running)
        XCTAssertTrue(session.isOpen)
        XCTAssertFalse(session.isRecording)
        XCTAssertTrue(SharedHandoff.isAppListening(in: handoff))
        session.append(Array(repeating: 0.5, count: 8_000)) // heard between dictations: never kept
        XCTAssertEqual(session.heldSampleCount, 0) // not even held in memory
        let second = UUID()
        keyboardRequests(second) // no URL: the keyboard posts the start notification instead
        await session.startFromKeyboard()
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(mic.starts, 1) // the open mic was reused
        XCTAssertEqual(state.phase, .recording)
        let words = Array(speech.reversed())
        session.append(words)
        await session.stop()
        XCTAssertEqual(try savedSamples(first), speech)
        XCTAssertEqual(try savedSamples(second), words)
        XCTAssertEqual(heard, [speech, words])
        var h = state
        XCTAssertEqual(h.consume(second, document: field), .insert("hello"))
    }

    @MainActor
    func testStartNotificationWithoutAKeyboardRequestStartsNothing() async {
        let session = makeSession(keepOpen: .fiveMinutes)
        session.observeKeyboard()
        let first = await recording(session)
        await session.stop()
        SharedHandoff.post(SharedHandoff.startNotification) // what any other app can do
        await session.startFromKeyboard()
        await session.tick()
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(state.sessionID, first) // nothing was claimed
        XCTAssertEqual(state.phase, .ready)
    }

    @MainActor
    func testClosedMicIgnoresTheStartNotificationSoTheKeyboardOpensTheApp() async {
        let session = makeSession() // closes after each dictation
        _ = await recording(session)
        await session.stop()
        XCTAssertFalse(mic.running)
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(SharedHandoff.isAppListening(in: handoff))
        let next = UUID()
        keyboardRequests(next)
        await session.startFromKeyboard()
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(mic.starts, 1)
        XCTAssertTrue(state.canStart(next)) // still pending for the app's URL
    }

    @MainActor
    func testLostStartNotificationIsPickedUpByTheTick() async {
        let session = makeSession(keepOpen: .fiveMinutes)
        _ = await recording(session)
        await session.stop()
        let next = UUID()
        keyboardRequests(next)
        await session.tick()
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(state.sessionID, next)
        XCTAssertEqual(state.phase, .recording)
    }

    @MainActor
    func testOpenMicClosesWhenItsTimeRunsOut() async {
        let session = makeSession(keepOpen: .fiveMinutes)
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        _ = await recording(session)
        await session.stop()
        XCTAssertEqual(shown, [.recording, .processing, .idle]) // 🤫 stays in the Live Activity while the mic is open
        await session.tick(now: Date().addingTimeInterval(300 - 5))
        XCTAssertTrue(session.isOpen)
        await session.tick(now: Date().addingTimeInterval(300 + 1))
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(mic.running)
        XCTAssertFalse(SharedHandoff.isAppListening(in: handoff))
        XCTAssertEqual(shown.last, .some(nil))
    }

    @MainActor
    func testMicKeptOpenForAnHourStaysOpenAndTurnsOff() async {
        let session = makeSession(keepOpen: .oneHour)
        _ = await recording(session)
        await session.stop()
        await session.tick(now: Date().addingTimeInterval(59 * 60))
        XCTAssertTrue(session.isOpen)
        XCTAssertTrue(mic.running)
        await session.turnOff()
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(mic.running)
        XCTAssertNil(session.activity)
        XCTAssertFalse(SharedHandoff.isAppListening(in: handoff))
    }

    func testLongestKeepOpenStaysUnderTheLiveActivityLimit() {
        // iOS ends a Live Activity after 8 hours; the mic must not outlive the 🤫 that shows it.
        XCTAssertLessThan(KeepOpen.allCases.map(\.seconds).max() ?? 0, 8 * 60 * 60)
    }

    @MainActor
    func testOnlyARecordingConvertsMicBuffers() async {
        let session = makeSession(keepOpen: .fiveMinutes)
        XCTAssertFalse(mic.capturing)
        _ = await recording(session)
        XCTAssertTrue(mic.capturing)
        await session.stop()
        XCTAssertTrue(mic.running)
        XCTAssertFalse(mic.capturing) // the open, idle mic drops buffers before resampling them
        let next = UUID()
        keyboardRequests(next)
        await session.startFromKeyboard()
        XCTAssertTrue(mic.capturing)
        session.cancel()
        XCTAssertFalse(mic.capturing)
    }

    @MainActor
    func testReadyIsSentAgainWhileTheMicStaysOpenSoItOnlyGoesStaleWhenTheAppDies() async {
        let session = makeSession(keepOpen: .fiveMinutes)
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        _ = await recording(session)
        await session.stop()
        XCTAssertEqual(shown, [.recording, .processing, .idle])
        await session.tick(now: Date().addingTimeInterval(30))
        XCTAssertEqual(shown.count, 3)
        await session.tick(now: Date().addingTimeInterval(DictationSession.activityRefresh + 1))
        XCTAssertEqual(shown, [.recording, .processing, .idle, .idle])
        XCTAssertLessThan(DictationSession.activityRefresh, Indicator.Mode.idle.staleAfter)
    }

    @MainActor
    func testStartFromTheKeyboardAfterTheEngineDiedClosesAndLeavesTheRequestForTheApp() async {
        let session = makeSession(keepOpen: .fiveMinutes)
        _ = await recording(session)
        await session.stop()
        mic.running = false // stopped by the system less than a second ago, before the next tick
        let next = UUID()
        keyboardRequests(next)
        await session.startFromKeyboard()
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(mic.starts, 1) // no start from the background
        XCTAssertTrue(state.canStart(next)) // the keyboard's fallback opens the app with it
        XCTAssertFalse(SharedHandoff.isAppListening(in: handoff))
    }

    @MainActor
    func testCancelWithTheMicOpenKeepsTheAudioAndShowsReady() async throws {
        let session = makeSession(keepOpen: .fiveMinutes)
        let id = await recording(session)
        session.cancel()
        XCTAssertTrue(session.isOpen)
        XCTAssertTrue(mic.running)
        XCTAssertEqual(session.activity, .idle)
        XCTAssertEqual(try savedSamples(id), speech)
        XCTAssertEqual(entry(id)?.outcome, .cancelled)
        XCTAssertEqual(state.phase, .cancelled)
    }

    @MainActor
    func testSupersedingRequestWithTheMicOpenKeepsTheOldAudioAndRecordsTheNewOne() async throws {
        let session = makeSession(keepOpen: .fiveMinutes)
        var shown: [Indicator.Mode?] = []
        session.onActivity = { shown.append($0) }
        let old = await recording(session)
        let new = UUID()
        keyboardRequests(new)
        await session.startFromKeyboard() // the open mic takes the new request without a URL
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(mic.starts, 1)
        XCTAssertEqual(try savedSamples(old), speech)
        XCTAssertEqual(entry(old)?.text, "hello") // late text goes to history
        XCTAssertEqual(state.sessionID, new)
        XCTAssertEqual(state.phase, .recording)
        XCTAssertEqual(shown, [.recording, .recording]) // never ended
        session.append(Array(speech.reversed()))
        await session.stop()
        XCTAssertEqual(try savedSamples(new), Array(speech.reversed()))
    }

    @MainActor
    func testTurnOffWhileRecordingKeepsAndDeliversTheRecording() async throws {
        let session = makeSession(keepOpen: .fiveMinutes)
        let id = await recording(session)
        await session.turnOff()
        XCTAssertFalse(mic.running)
        XCTAssertEqual(try savedSamples(id), speech)
        XCTAssertEqual(state.phase, .ready)
    }

    @MainActor
    func testOpenMicThatTheSystemStoppedCloses() async {
        let session = makeSession(keepOpen: .fiveMinutes)
        _ = await recording(session)
        await session.stop()
        mic.running = false // a call or a route change stopped the engine
        await session.tick()
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(SharedHandoff.isAppListening(in: handoff))
        XCTAssertNil(session.activity)
    }

    @MainActor
    func testErrorWhileTheMicIsOpenGoesBackToReady() async {
        let session = makeSession(keepOpen: .fiveMinutes)
        _ = await recording(session, Array(speech.prefix(DictationSession.minimumSamples - 1)))
        await session.stop()
        XCTAssertEqual(session.activity, .error)
        XCTAssertTrue(session.isOpen)
        await session.tick(now: Date().addingTimeInterval(1))
        XCTAssertEqual(session.activity, .error)
        await session.tick(now: Date().addingTimeInterval(DictationSession.errorShown + 1))
        XCTAssertEqual(session.activity, .idle)
    }

    @MainActor
    func testShorterKeepOpenAppliesToAnAlreadyOpenMic() async {
        let session = makeSession(keepOpen: .oneHour)
        _ = await recording(session)
        await session.stop()
        session.keepOpen = .afterEach
        await session.tick(now: Date().addingTimeInterval(1))
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(mic.running)
    }

    @MainActor
    func testKeepOpenDefaultsToFiveMinutesAndIsRemembered() {
        UserDefaults(suiteName: settingsSuite)!.removeObject(forKey: "keepOpen")
        let session = DictationSession(mic: mic, directory: dir, handoff: handoff, settings: UserDefaults(suiteName: settingsSuite)!) { true }
        XCTAssertEqual(session.keepOpen, .fiveMinutes)
        session.keepOpen = .oneHour
        let reloaded = DictationSession(mic: mic, directory: dir, handoff: handoff, settings: UserDefaults(suiteName: settingsSuite)!) { true }
        XCTAssertEqual(reloaded.keepOpen, .oneHour)
    }

    @MainActor
    func testTranscriptionRunsInsideBackgroundWorkThatEndsWhenTheTextIsDelivered() async {
        let session = makeSession() // the mic closes when the recording stops, so only background time keeps the app up
        var begun = 0, ended = 0
        session.beginBackgroundWork = {
            begun += 1
            return { ended += 1 }
        }
        session.modelReady { _ in
            XCTAssertEqual(begun, 1) // asked for before the model runs
            XCTAssertEqual(ended, 0)
            return "hello"
        }
        _ = await recording(session)
        await session.stop()
        XCTAssertEqual(begun, 1)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(state.phase, .ready)
    }

    // MARK: Goal rule 9: Donate.

    func testDonateLinksPointToBothPages() {
        XCTAssertEqual(Donate.coffee.absoluteString, "https://buymeacoffee.com/sorcecoder")
        XCTAssertEqual(Donate.sponsors.absoluteString, "https://github.com/sponsors/backant-io")
    }
}
