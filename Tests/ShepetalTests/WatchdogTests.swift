import XCTest
import ShepetalCore
@testable import Shepetal

/// F99: the watchdog on a spawned /bin/sleep instead of the app, and an injected relaunch instead of
/// opening anything. A crash must bring the app back once, after the backoff; a quit must not.
final class WatchdogTests: XCTestCase {
    var dir: URL!
    var sleeper: Process!
    var relaunches = 0
    var stays = 0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
    }

    override func tearDown() {
        if sleeper.isRunning { kill(sleeper.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }

    var policy: Relaunch {
        (try? Data(contentsOf: dir.appendingPathComponent("relaunch.json")))
            .flatMap { try? JSONDecoder().decode(Relaunch.self, from: $0) } ?? Relaunch()
    }

    func watch(started: Date = Date()) -> DispatchSourceProcess {
        Watchdog.watch(pid: sleeper.processIdentifier, dir: dir, started: started,
                       relaunch: { self.relaunches += 1 }, stay: { self.stays += 1 })
    }

    /// Runs the main queue (where the watchdog's handlers run) until `done` or `seconds` pass.
    func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testKillNineReopensOnceAfterTheBackoff() {
        let source = watch(started: Date().addingTimeInterval(-300))  // ran 5 minutes: the first crash
        let killed = Date()
        kill(sleeper.processIdentifier, SIGKILL)
        spin(0.8)
        XCTAssertEqual(relaunches, 0, "reopened before the 1 s backoff")
        spin(3) { relaunches > 0 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(killed), 1)
        spin(1.5)
        XCTAssertEqual(relaunches, 1, "reopened more than once")
        XCTAssertEqual(stays, 0)
        XCTAssertEqual(policy.crashes, 1, "the crash is not recorded for the next one")
        withExtendedLifetime(source) {}
    }

    func testMarkerThenExitStaysQuit() throws {
        Watchdog.markCleanQuit(dir: dir, pid: sleeper.processIdentifier)  // what Quit, exit and SIGTERM call
        try JSONEncoder().encode(Relaunch(crashes: 2)).write(to: dir.appendingPathComponent("relaunch.json"))
        let source = watch()
        kill(sleeper.processIdentifier, SIGTERM)  // what the installer sends; the app writes the marker first
        spin(3) { stays > 0 }
        spin(1.5)
        XCTAssertEqual(stays, 1)
        XCTAssertEqual(relaunches, 0, "a quit was taken for a crash")
        XCTAssertEqual(policy, Relaunch(), "a quit keeps the count of earlier crashes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clean-quit").path))
        withExtendedLifetime(source) {}
    }

    func testAnotherProcessesMarkerIsStillACrash() throws {
        Watchdog.markCleanQuit(dir: dir, pid: 1)  // an earlier copy's quit
        let source = watch()
        kill(sleeper.processIdentifier, SIGKILL)
        spin(3) { relaunches > 0 }
        XCTAssertEqual(relaunches, 1)
        withExtendedLifetime(source) {}
    }

    func testFourthQuickCrashStaysDownAndTheNextLaunchSaysSoOnce() throws {
        try JSONEncoder().encode(Relaunch(crashes: 3)).write(to: dir.appendingPathComponent("relaunch.json"))
        let source = watch()
        kill(sleeper.processIdentifier, SIGKILL)
        spin(3) { stays > 0 }
        spin(1.5)
        XCTAssertEqual(relaunches, 0, "a crash loop is reopened forever")
        XCTAssertEqual(stays, 1)
        XCTAssertEqual(Watchdog.takeGaveUp(dir: dir), Relaunch.gaveUpHint)
        XCTAssertNil(Watchdog.takeGaveUp(dir: dir), "the hint shows at every launch, not once")
        withExtendedLifetime(source) {}
    }

    /// The app can crash before the watchdog has started to watch it.
    func testAppGoneBeforeWatchingIsStillACrash() {
        kill(sleeper.processIdentifier, SIGKILL)
        sleeper.waitUntilExit()
        let source = watch()
        spin(3) { relaunches > 0 }
        XCTAssertEqual(relaunches, 1)
        withExtendedLifetime(source) {}
    }

    func testOnlyANormalLaunchOfTheBundleStartsIt() {
        let app = URL(fileURLWithPath: "/Applications/Shepetal.app")
        XCTAssertTrue(Watchdog.wanted(args: ["/Applications/Shepetal.app/Contents/MacOS/Shepetal"], bundle: app))
        for mode in ["--e2e", "--e2e-meeting", "--postinstall", "--quit-from-menu-after", "--no-permission-prompts", Watchdog.flag] {
            XCTAssertFalse(Watchdog.wanted(args: ["Shepetal", mode, "1"], bundle: app), mode)
        }
        XCTAssertFalse(Watchdog.wanted(args: ["shepetal"], bundle: URL(fileURLWithPath: "/tmp/.build/debug")), "swift run: nothing to open again")
    }
}
