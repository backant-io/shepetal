import XCTest
@testable import ShepetalCore

/// F124: where Move to Applications puts Shepetal, and when it asks again. A wrong target fails the move for a
/// standard account or under the old .pkg's root-owned copy; asking only once ever leaves a newer download
/// stranded in Downloads, where it cannot update itself.
final class AppLocationTests: XCTestCase {
    let home = "/Users/p"

    /// `writable` and `exists` stand in for FileManager: nothing on this Mac is looked at. This build is 512.
    func destination(writable: Set<String>, exists: Set<String> = [], systemBuild: Int? = nil) -> String {
        MovePrompt.destination(home: home, writable: writable.contains, exists: exists.contains,
                               systemBuild: systemBuild, runningBuild: 512)
    }

    func testApplicationsWhenItCanBeWritten() {
        XCTAssertEqual(destination(writable: ["/Applications"]), "/Applications/Shepetal.app")
        XCTAssertEqual(destination(writable: ["/Applications", "/Applications/Shepetal.app"], exists: ["/Applications/Shepetal.app"]),
                       "/Applications/Shepetal.app", "a user-owned older copy is replaced in place")
    }

    func testOwnApplicationsForAStandardAccount() {
        XCTAssertEqual(destination(writable: []), "/Users/p/Applications/Shepetal.app")
    }

    func testOwnApplicationsWhenTheCopyThereIsRootOwned() {
        XCTAssertEqual(destination(writable: ["/Applications"], exists: ["/Applications/Shepetal.app"]),
                       "/Users/p/Applications/Shepetal.app", "the old .pkg's copy cannot be trashed without a password")
    }

    func testNotNowIsRememberedPerVersion() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "shepetal-test-\(UUID().uuidString)"))
        XCTAssertFalse(MovePrompt.asked(d, version: "512"))
        MovePrompt.remember(d, version: "512")
        XCTAssertTrue(MovePrompt.asked(d, version: "512"), "the same build asks once")
        XCTAssertFalse(MovePrompt.asked(d, version: "600"), "a newer download asks again")
    }

    // An admin installed a newer build in /Applications, and a standard account (or the old .pkg's root-owned copy)
    // runs an older download: that copy is opened, not shadowed by the older one copied to ~/Applications.
    func testANewerCopyInApplicationsIsOpenedWhereverTheMoveWouldGo() {
        let system = ["/Applications/Shepetal.app"] as Set
        for writable in [[], ["/Applications"]] as [Set<String>] {
            XCTAssertEqual(destination(writable: writable, exists: system, systemBuild: 600), "/Applications/Shepetal.app",
                           "writable: \(writable)")
        }
        XCTAssertEqual(MovePrompt.move(installedBuild: 600, runningBuild: 512), .openInstalled, "there, nothing is copied or trashed")
        XCTAssertEqual(destination(writable: [], exists: system, systemBuild: 512), "/Users/p/Applications/Shepetal.app",
                       "the same build there is not opened instead")
        XCTAssertEqual(destination(writable: [], exists: system, systemBuild: 400), "/Users/p/Applications/Shepetal.app")
    }
}
