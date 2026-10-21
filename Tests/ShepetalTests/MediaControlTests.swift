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
    private let music = AudioProcess(pid: 1, bundleID: "com.apple.Music", output: true)

    override func setUp() {
        suite = "shepetal-media-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.set(true, forKey: MediaControl.muteKey)
        defaults.set(true, forKey: MediaControl.pauseKey)
        applied = []; reads = 0; mutedUIDs = []; defaultUID = "speakers"
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func control(meeting: Bool = false) -> MediaControl {
        let system = MediaControl.System(
            processes: { [unowned self] in reads += 1; return [AudioProcess(pid: 1, output: !applied.contains(.playPause))] },
            output: { [unowned self] uid in
                reads += 1
                let u = uid ?? defaultUID
                return OutputDevice(uid: u, muted: mutedUIDs.contains(u), volume: 0.5)
            },
            apply: { [unowned self] in
                applied.append($0)
                if case .setMute(let uid, let on) = $0 { if on { mutedUIDs.insert(uid) } else { mutedUIDs.remove(uid) } }
            })
        return MediaControl(system: system, defaults: defaults, meeting: { meeting })
    }

    private func settle(_ seconds: TimeInterval = 0.15) {
        let done = expectation(description: "main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testHeldPastTheThresholdMutesAndPausesThenEndRestores() {
        let media = control()
        media.begin(after: 0.05) { true }
        settle()
        XCTAssertEqual(applied, [.playPause, .setMute(uid: "speakers", true)])
        media.end()
        XCTAssertEqual(applied.suffix(2), [.setMute(uid: "speakers", false), .playPause])
    }

    // Headphones plugged in mid-dictation become the default: the speakers we muted get unmuted, the headphones
    // are left alone.
    func testEndRestoresTheDeviceItMutedNotTheDefault() {
        let media = control()
        media.begin(after: 0) { true }
        settle()
        defaultUID = "headphones"
        media.end()
        XCTAssertEqual(applied.last(where: { if case .setMute = $0 { true } else { false } }), .setMute(uid: "speakers", false))
        XCTAssertTrue(mutedUIDs.isEmpty)
    }

    // fn+Delete, fn+arrow: the session ends before the hold threshold.
    func testEndingBeforeTheThresholdTouchesNothing() {
        let media = control()
        media.begin(after: 0.05) { true }
        media.end()
        settle()
        XCTAssertEqual(applied, [])
    }

    // A short tap waiting for its second tap is not held: nothing yet. The second tap locks hands-free and acts.
    func testWaitingForTheSecondTapActsOnlyOnTheLock() {
        let media = control()
        var live = false
        media.begin(after: 0.05) { live }
        settle()
        XCTAssertEqual(applied, [])
        live = true
        media.begin(after: 0) { live }
        settle()
        XCTAssertEqual(applied, [.playPause, .setMute(uid: "speakers", true)])
    }

    // fn+Space sends start and the lock together; a hold that later locks calls begin twice too. One pause only.
    func testStartThenLockActsOnce() {
        let media = control()
        media.begin(after: 0.05) { true }
        settle()
        media.begin(after: 0) { true }
        settle()
        XCTAssertEqual(applied.filter { $0 == .playPause }.count, 1)
    }

    func testBothSettingsOffReadNothing() {
        defaults.set(false, forKey: MediaControl.muteKey)
        defaults.set(false, forKey: MediaControl.pauseKey)
        let media = control()
        media.begin(after: 0) { true }
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
        media.begin(after: 0) { true }
        settle()
        XCTAssertEqual(applied, [])
    }

    func testMeetingMeansNothingHappens() {
        let media = control(meeting: true)
        media.begin(after: 0) { true }
        settle()
        media.end()
        XCTAssertEqual(applied, [])
    }
}
