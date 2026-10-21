import Foundation
import XCTest
@testable import ShepetalCore

/// The update hint shows exactly once per update: a first install, a relaunch and a downgrade stay silent,
/// because a hint nobody asked for at every launch is noise. Each test has its own defaults suite, never the app's.
final class WhatsNewTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "io.backant.shepetal.tests.whatsnew.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testAFirstInstallIsSilentAndRecordsTheVersion() {
        XCTAssertNil(WhatsNew.launch(current: "0.2.0", hadData: false, defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: WhatsNew.defaultsKey), "0.2.0")
    }

    func testAnUpdateAnnouncesOnceThenARelaunchIsSilent() {
        _ = WhatsNew.launch(current: "0.1.0", hadData: false, defaults: defaults)
        XCTAssertEqual(WhatsNew.launch(current: "0.2.0", hadData: true, defaults: defaults), "0.2.0")
        XCTAssertNil(WhatsNew.launch(current: "0.2.0", hadData: true, defaults: defaults))
        XCTAssertNil(WhatsNew.launch(current: "0.2.0", hadData: true, defaults: defaults))
    }

    /// 0.1.0 never recorded its version: its data on disk is how its users still get the hint for their first update.
    func testAnUpdateFrom010WhichRecordedNothingAnnounces() {
        XCTAssertEqual(WhatsNew.launch(current: "0.2.0", hadData: true, defaults: defaults), "0.2.0")
        XCTAssertNil(WhatsNew.launch(current: "0.2.0", hadData: true, defaults: defaults))
    }

    func testRunning010OverItsOwnDataIsSilent() {
        XCTAssertNil(WhatsNew.launch(current: "0.1.0", hadData: true, defaults: defaults))
    }

    func testADowngradeIsSilent() {
        _ = WhatsNew.launch(current: "0.3.0", hadData: false, defaults: defaults)
        XCTAssertNil(WhatsNew.launch(current: "0.2.0", hadData: true, defaults: defaults))
        XCTAssertNil(WhatsNew.announce(lastSeen: "1.0.0", current: "0.9.9"))
    }

    /// As text "0.1.10" < "0.1.9"; as versions it is the other way round.
    func testVersionsCompareAsNumbers() {
        XCTAssertTrue(WhatsNew.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertFalse(WhatsNew.isNewer("0.1.9", than: "0.1.10"))
        XCTAssertTrue(WhatsNew.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertTrue(WhatsNew.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(WhatsNew.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertEqual(WhatsNew.announce(lastSeen: "0.1.9", current: "0.1.10"), "0.1.10")
    }
}
