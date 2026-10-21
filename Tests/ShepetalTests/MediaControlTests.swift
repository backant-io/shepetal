import XCTest
import ShepetalCore
@testable import Shepetal

/// The shell's timing around MediaPolicy, with a fake Core Audio: no device is muted and no media key is posted.
/// fn starts a session on its press, so fn+Delete and a short tap reach `begin`; they must never pause the user's music.
@MainActor
final class MediaControlTests: XCTestCase {
    private var applied: [MediaAction] = []
    private var reads = 0
    private var defaults: UserDefaults!
    private var suite = ""
    private var mutedUIDs: Set<String> = []
    private var defaultUID = "speakers"
    /// The pids running output. Real players keep it running for a moment after the key, so the key alone
    /// changes nothing here; `key` is what the media key does to the players.
    private var running: Set<Int32> = [1]
    private var key: () -> Void = {}

    override func setUp() {
        suite = "shepetal-media-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.set(true, forKey: MediaControl.muteKey)
        defaults.set(true, forKey: MediaControl.pauseKey)
        applied = []; reads = 0; mutedUIDs = []; defaultUID = "speakers"; running = [1]; key = {}
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func control(meeting: Bool = false) -> MediaControl {
        let system = MediaControl.System(
            processes: { [unowned self] in reads += 1; return running.map { AudioProcess(pid: $0, output: true) } },
            output: { [unowned self] uid in
                reads += 1
                let u = uid ?? defaultUID
                return OutputDevice(uid: u, muted: mutedUIDs.contains(u), volume: 0.5)
            },
            apply: { [unowned self] in
                applied.append($0)
                if case .setMute(let uid, let on) = $0 { if on { mutedUIDs.insert(uid) } else { mutedUIDs.remove(uid) } }
                if $0 == .playPause { key() }
            })
        let media = MediaControl(system: system, defaults: defaults, meeting: { meeting })
        media.settle = 0.1
        return media
    }

    private func settle(_ seconds: TimeInterval = 0.15) {
        let done = expectation(description: "main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testHeldPastTheThresholdMutesAndPausesThenEndRestores() {
        let media = control()
        media.begin(mute: 0.02, pause: 0.05) { true }
        settle()
        XCTAssertEqual(applied, [.setMute(uid: "speakers", true), .playPause])
        running = []  // Music stopped
        media.end()
        XCTAssertEqual(applied.suffix(2), [.setMute(uid: "speakers", false), .playPause])
    }

    // Headphones plugged in mid-dictation become the default: the speakers we muted get unmuted, the headphones
    // are left alone.
    func testEndRestoresTheDeviceItMutedNotTheDefault() {
        let media = control()
        media.begin(mute: 0, pause: 0) { true }
        settle()
        defaultUID = "headphones"
        media.end()
        XCTAssertEqual(applied.last(where: { if case .setMute = $0 { true } else { false } }), .setMute(uid: "speakers", false))
        XCTAssertTrue(mutedUIDs.isEmpty)
    }

    // fn+Delete, fn+arrow: the session ends before the hold threshold.
    func testEndingBeforeTheThresholdTouchesNothing() {
        let media = control()
        media.begin(mute: 0.05, pause: 0.05) { true }
        media.end()
        settle()
        XCTAssertEqual(applied, [])
    }

    // fn+arrow after the hold threshold but inside the chord window cancels: the mute is undone exactly, but a
    // pause key sent then would leave Music paused (its output still runs at the cancel), so none is sent.
    func testAChordInsideTheChordWindowNeverPressesTheKey() {
        let media = control()
        media.begin(mute: 0.02, pause: 0.3) { true }
        settle()
        XCTAssertEqual(applied, [.setMute(uid: "speakers", true)])
        media.end()
        settle(0.35)
        XCTAssertEqual(applied, [.setMute(uid: "speakers", true), .setMute(uid: "speakers", false)])
    }

    // A game holds the output and Music is paused: the key starts Music. It is pressed again a moment later, so
    // Music neither plays into the recording nor goes on after it.
    func testAPlayerTheKeyStartedIsPausedAgainSoon() {
        defaults.set(false, forKey: MediaControl.muteKey)
        running = [2]
        key = { [unowned self] in if running.contains(1) { running.remove(1) } else { running.insert(1) } }
        let media = control()
        media.begin(mute: 0, pause: 0) { true }
        settle(0.3)
        XCTAssertEqual(applied, [.playPause, .playPause])
        XCTAssertEqual(running, [2])
        media.end()
        XCTAssertEqual(applied, [.playPause, .playPause])
    }

    // A short tap waiting for its second tap is not held: nothing yet. The second tap locks hands-free and acts.
    func testWaitingForTheSecondTapActsOnlyOnTheLock() {
        let media = control()
        var live = false
        media.begin(mute: 0.02, pause: 0.05) { live }
        settle()
        XCTAssertEqual(applied, [])
        live = true
        media.begin(mute: 0, pause: 0.02) { live }
        settle()
        XCTAssertEqual(applied, [.setMute(uid: "speakers", true), .playPause])
    }

    // fn+Space sends start and the lock together; a hold that later locks calls begin twice too. Music still
    // runs output after the first key, so a second key would start it again: one pause and one mute only.
    func testStartThenLockActsOnce() {
        let media = control()
        media.begin(mute: 0.02, pause: 0.05) { true }
        settle()
        media.begin(mute: 0, pause: 0) { true }
        settle()
        XCTAssertEqual(applied, [.setMute(uid: "speakers", true), .playPause])
    }

    func testBothSettingsOffReadNothing() {
        defaults.set(false, forKey: MediaControl.muteKey)
        defaults.set(false, forKey: MediaControl.pauseKey)
        let media = control()
        media.begin(mute: 0, pause: 0) { true }
        settle()
        media.end()
        XCTAssertEqual(applied, [])
        XCTAssertEqual(reads, 0)
    }

    func testSettingsAreOffByDefault() throws {
        let fresh = "shepetal-media-default-\(UUID().uuidString)"
        let plain = try XCTUnwrap(UserDefaults(suiteName: fresh))
        defer { plain.removePersistentDomain(forName: fresh) }
        defaults = plain
        let media = control()
        media.begin(mute: 0, pause: 0) { true }
        settle()
        XCTAssertEqual(applied, [])
    }

    func testMeetingMeansNothingHappens() {
        let media = control(meeting: true)
        media.begin(mute: 0, pause: 0) { true }
        settle()
        media.end()
        XCTAssertEqual(applied, [])
    }
}
