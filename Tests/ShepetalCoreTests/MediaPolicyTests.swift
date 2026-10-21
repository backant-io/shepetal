import XCTest
@testable import ShepetalCore

extension MediaPolicy {
    /// Both steps at once, as on the hands-free lock.
    mutating func start(processes: [AudioProcess], output: OutputDevice?, meeting: Bool) -> [MediaAction] {
        startMute(processes: processes, output: output, meeting: meeting) + startPause(processes: processes, meeting: meeting)
    }
}

/// F09: muting and pausing must never leave the user worse off than before the dictation. Each test is one way
/// it could: silencing a call, unmuting what the user muted, starting playback nobody asked for.
final class MediaPolicyTests: XCTestCase {
    static let me: Int32 = 100
    let music = AudioProcess(pid: 1, bundleID: "com.apple.Music", output: true)
    let speakers = OutputDevice(uid: "speakers", muted: false, volume: 0.6)

    func policy(mute: Bool = true, pause: Bool = true) -> MediaPolicy {
        var p = MediaPolicy(ownPID: Self.me, ownBundleID: "io.backant.shepetal")
        p.mute = mute
        p.pause = pause
        return p
    }

    func testMutesAndPausesWhatIsPlayingThenRestoresBoth() {
        var p = policy()
        XCTAssertEqual(p.start(processes: [music], output: speakers, meeting: false),
                       [.setMute(uid: "speakers", true), .playPause])
        let paused = AudioProcess(pid: 1, bundleID: "com.apple.Music", output: false)
        var muted = speakers; muted.muted = true
        XCTAssertEqual(p.stop(processes: [paused], device: { $0 == "speakers" ? muted : nil }),
                       [.setMute(uid: "speakers", false), .playPause])
    }

    func testEachSettingWorksAlone() {
        var p = policy(mute: false)
        XCTAssertEqual(p.start(processes: [music], output: speakers, meeting: false), [.playPause])
        p = policy(pause: false)
        XCTAssertEqual(p.start(processes: [music], output: speakers, meeting: false), [.setMute(uid: "speakers", true)])
    }

    // Muting an idle Mac would only silence the next notification the user expects to hear.
    func testNothingPlayingMeansNothingHappens() {
        var p = policy()
        let idle = AudioProcess(pid: 1, output: false)
        XCTAssertEqual(p.start(processes: [idle], output: speakers, meeting: false), [])
        XCTAssertEqual(p.stop(processes: [idle], device: { _ in self.speakers }), [])
    }

    // shepetal's own output (Play in History) is not "other audio".
    func testOwnOutputDoesNotCount() {
        var p = policy()
        let me = AudioProcess(pid: Self.me, output: true)
        let meByBundle = AudioProcess(pid: 7, bundleID: "io.backant.shepetal", output: true)
        XCTAssertEqual(p.start(processes: [me, meByBundle], output: speakers, meeting: false), [])
    }

    // Muting or pausing during a call would cut the call.
    func testAMeetingOrACallOnTheMicMeansNothingHappens() {
        var p = policy()
        XCTAssertEqual(p.start(processes: [music], output: speakers, meeting: true), [])
        p = policy()
        let zoom = AudioProcess(pid: 2, bundleID: "us.zoom.xos", output: true, input: true)
        XCTAssertEqual(p.start(processes: [music, zoom], output: speakers, meeting: false), [])
        // Our own mic (the dictation itself) is not a call.
        p = policy()
        let dictating = AudioProcess(pid: Self.me, input: true)
        XCTAssertEqual(p.start(processes: [music, dictating], output: speakers, meeting: false).count, 2)
    }

    // The user muted it, or set it to zero: we owe nothing, so we must not unmute it at the end.
    func testAlreadySilentOrUnreadableOutputIsSkipped() {
        for output in [OutputDevice(uid: "s", muted: true, volume: 0.6), OutputDevice(uid: "s", muted: false, volume: 0),
                       OutputDevice(uid: "s", muted: nil, volume: nil)] {
            var p = policy(pause: false)
            XCTAssertEqual(p.start(processes: [music], output: output, meeting: false), [], "\(output)")
            XCTAssertEqual(p.stop(processes: [music], device: { _ in OutputDevice(uid: "s", muted: true, volume: 0) }), [])
        }
        var p = policy(pause: false)
        XCTAssertEqual(p.start(processes: [music], output: nil, meeting: false), [])
    }

    // No settable mute (some USB and HDMI outputs): volume to zero, and back to exactly where it was.
    func testVolumeFallbackRestoresTheOldVolume() {
        var p = policy(pause: false)
        let hdmi = OutputDevice(uid: "hdmi", muted: nil, volume: 0.35, canMute: false)
        XCTAssertEqual(p.start(processes: [music], output: hdmi, meeting: false), [.setVolume(uid: "hdmi", 0)])
        let zero = OutputDevice(uid: "hdmi", muted: nil, volume: 0, canMute: false)
        XCTAssertEqual(p.stop(processes: [music], device: { _ in zero }), [.setVolume(uid: "hdmi", 0.35)])
        // Neither mute nor volume can be set: nothing, and nothing owed.
        p = policy(pause: false)
        let fixed = OutputDevice(uid: "x", muted: false, volume: 0.5, canMute: false, canSetVolume: false)
        XCTAssertEqual(p.start(processes: [music], output: fixed, meeting: false), [])
    }

    // The restore is owed to the device we muted, by UID: switching to headphones mid-dictation must not unmute
    // the headphones, and the speakers we muted still get unmuted.
    func testRestoreIsOwedToTheDeviceWeMuted() {
        var p = policy(pause: false)
        _ = p.start(processes: [music], output: speakers, meeting: false)
        var asked: [String] = []
        let actions = p.stop(processes: [music], device: { uid in
            asked.append(uid)
            return OutputDevice(uid: uid, muted: true, volume: 0.6)
        })
        XCTAssertEqual(asked, ["speakers"])
        XCTAssertEqual(actions, [.setMute(uid: "speakers", false)])
        // The device is gone (unplugged): nothing to restore, nothing left owed.
        p = policy(pause: false)
        _ = p.start(processes: [music], output: speakers, meeting: false)
        XCTAssertEqual(p.stop(processes: [music], device: { _ in nil }), [])
        XCTAssertNil(p.owed)
    }

    // The user changed the device during the dictation: their choice wins.
    func testUserChangeSinceTheMuteIsKept() {
        var p = policy(pause: false)
        _ = p.start(processes: [music], output: speakers, meeting: false)
        XCTAssertEqual(p.stop(processes: [music], device: { _ in self.speakers }), [], "user unmuted it already")
        p = policy(pause: false)
        _ = p.start(processes: [music], output: OutputDevice(uid: "h", muted: nil, volume: 0.4, canMute: false), meeting: false)
        XCTAssertEqual(p.stop(processes: [music], device: { _ in OutputDevice(uid: "h", muted: nil, volume: 0.8, canMute: false) }), [],
                       "user turned it up already")
    }

    // Play is the same key as pause: sending it when our pause did not stop the player would start playback.
    func testOnlyWhatWePausedIsResumed() {
        var p = policy(mute: false)
        _ = p.start(processes: [music], output: speakers, meeting: false)
        XCTAssertEqual(p.stop(processes: [music], device: { _ in nil }), [], "still playing: the key did not pause it")
        // Nothing was paused (nothing played at the start): a player started during the dictation stays as it is.
        p = policy(mute: false)
        _ = p.start(processes: [], output: speakers, meeting: false)
        XCTAssertEqual(p.stop(processes: [AudioProcess(pid: 1, output: false)], device: { _ in nil }), [])
        // Two players, one of them stopped by the key: resume.
        p = policy(mute: false)
        let chrome = AudioProcess(pid: 3, bundleID: "com.google.Chrome.helper", output: true)
        _ = p.start(processes: [music, chrome], output: speakers, meeting: false)
        XCTAssertEqual(p.stop(processes: [chrome], device: { _ in nil }), [.playPause])
    }

    // Mute comes at the hold threshold, pause only at the chord window: each step does only its own part.
    func testMuteAndPauseAreSeparateSteps() {
        var p = policy()
        XCTAssertEqual(p.startMute(processes: [music], output: speakers, meeting: false), [.setMute(uid: "speakers", true)])
        XCTAssertEqual(p.startPause(processes: [music], meeting: false), [.playPause])
    }

    // The key is a toggle: with a game or afplay holding the output and Music paused, it starts Music. Music must
    // not play on into the recording or after it.
    func testAPlayerTheKeyStartedIsPressedAgain() {
        let afplay = AudioProcess(pid: 4, bundleID: "", output: true)
        var p = policy(mute: false)
        XCTAssertEqual(p.startPause(processes: [afplay], meeting: false), [.playPause])
        XCTAssertEqual(p.stop(processes: [afplay, music], device: { _ in nil }), [.playPause], "at the end")
        // A second after the key: pressed again at once, and nothing is left for the end.
        p = policy(mute: false)
        _ = p.startPause(processes: [afplay], meeting: false)
        XCTAssertEqual(p.check(processes: [afplay]), [], "nothing changed: wait for the end")
        XCTAssertEqual(p.check(processes: [afplay, music]), [.playPause])
        XCTAssertEqual(p.stop(processes: [afplay, music], device: { _ in nil }), [])
        // What we paused stopped: the pause worked, so the check leaves it alone, even with another player started.
        p = policy(mute: false)
        _ = p.startPause(processes: [music], meeting: false)
        XCTAssertEqual(p.check(processes: [AudioProcess(pid: 3, output: true)]), [])
        XCTAssertEqual(p.stop(processes: [], device: { _ in nil }), [.playPause])
    }

    // The hands-free lock calls start again: a second pause key would restart the media mid-dictation.
    func testSecondStartInOneDictationDoesNothing() {
        var p = policy()
        XCTAssertEqual(p.start(processes: [music], output: speakers, meeting: false).count, 2)
        XCTAssertEqual(p.start(processes: [music], output: speakers, meeting: false), [])
        var muted = speakers; muted.muted = true
        _ = p.stop(processes: [], device: { _ in muted })
        // The next dictation starts fresh.
        XCTAssertEqual(p.start(processes: [music], output: speakers, meeting: false).count, 2)
    }

    // The process list is a Core Audio call on the main thread: only read when something was paused.
    func testStopReadsProcessesOnlyWhenSomethingWasPaused() {
        var p = policy(pause: false)
        var reads = 0
        func read() -> [AudioProcess] { reads += 1; return [] }
        _ = p.start(processes: [music], output: speakers, meeting: false)
        _ = p.stop(processes: read(), device: { _ in nil })
        XCTAssertEqual(reads, 0)
    }
}
