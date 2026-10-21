import XCTest
@testable import ShepetalCore

/// F124: where Move to Applications puts Shepetal, and when it asks again. A wrong target fails the move for a
/// standard account or under the old .pkg's root-owned copy; asking only once ever leaves a newer download
/// stranded in Downloads, where it cannot update itself.
final class AppLocationTests: XCTestCase {
    let home = "/Users/p"

    /// `writable` and `exists` stand in for FileManager: nothing on this Mac is looked at.
    func destination(writable: Set<String>, exists: Set<String> = []) -> String {
        MovePrompt.destination(home: home, writable: writable.contains, exists: exists.contains)
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

    // Not a bundle we ship: `swift run`, .build and dist/ never ask.
    func testDevBuildsAreNotOffered() {
        for (path, id) in [("/Users/p/src/shepetal/.build/debug/shepetal", ""), ("/Users/p/src/shepetal/dist/Shepetal.app", "io.backant.shepetal")] {
            XCTAssertFalse(MovePrompt.offers(path: path, home: home, readOnlyVolume: false, bundleID: id, asked: false), path)
        }
    }
}
