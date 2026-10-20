import XCTest
@testable import ShepetalCore

final class WatchersTests: XCTestCase {
    enum P { case mic, ax }

    // A permission missing at launch is onboarding, not something the user just turned off.
    func testFirstObservationIsNotARevocation() {
        var w = PermissionWatch<P>()
        XCTAssertEqual(w.observe([.mic: false, .ax: false]), [])
    }

    func testRevokedReportedOnce() {
        var w = PermissionWatch<P>()
        XCTAssertEqual(w.observe([.mic: true, .ax: true]), [])
        XCTAssertEqual(w.observe([.mic: false, .ax: true]), [.mic])
        XCTAssertEqual(w.observe([.mic: false, .ax: true]), [], "staying off must not nag on every poll")
        XCTAssertEqual(PermissionWatch<P>.message("Accessibility"), "Accessibility access was turned off")
    }

    func testRegrantClears() {
        var w = PermissionWatch<P>()
        _ = w.observe([.mic: true, .ax: true])
        XCTAssertEqual(w.observe([.mic: false, .ax: true]), [.mic])
        XCTAssertEqual(w.observe([.mic: true, .ax: true]), [])
        XCTAssertEqual(w.observe([.mic: false, .ax: true]), [.mic], "a second revocation is reported again")
    }

    // Turning the permission back on clears the yellow ring within one poll, without waiting for a dictation.
    func testRegrantAfterRevocationIsReportedOnce() {
        var w = PermissionWatch<P>()
        _ = w.observe([.mic: true, .ax: true])
        XCTAssertFalse(w.restored, "nothing was revoked")
        _ = w.observe([.mic: false, .ax: false])
        XCTAssertFalse(w.restored)
        _ = w.observe([.mic: true, .ax: false])
        XCTAssertFalse(w.restored, "Accessibility is still off, so the ring stays")
        _ = w.observe([.mic: true, .ax: true])
        XCTAssertTrue(w.restored)
        _ = w.observe([.mic: true, .ax: true])
        XCTAssertFalse(w.restored, "once, not on every poll")
    }

    // A permission missing at launch and granted later is onboarding, not a re-grant.
    func testGrantAfterLaunchIsNotARestore() {
        var w = PermissionWatch<P>()
        _ = w.observe([.mic: false, .ax: true])
        _ = w.observe([.mic: true, .ax: true])
        XCTAssertFalse(w.restored)
    }

    // Terminal's Secure Keyboard Entry can stay on for hours; one notice per episode, not one every 2 s.
    func testSecureInputNoticeOnRisingEdgeOnly() {
        var w = SecureInputWatch()
        XCTAssertNil(w.poll(enabled: false, ownerPid: nil, ownerName: nil, selfPid: 1))
        XCTAssertEqual(w.poll(enabled: true, ownerPid: 42, ownerName: "Terminal", selfPid: 1),
                       .on("Secure input is on in Terminal, so fn can't be heard"))
        XCTAssertNil(w.poll(enabled: true, ownerPid: 42, ownerName: "Terminal", selfPid: 1))
        XCTAssertNil(w.poll(enabled: true, ownerPid: 42, ownerName: "Terminal", selfPid: 1))
        XCTAssertEqual(w.poll(enabled: false, ownerPid: nil, ownerName: nil, selfPid: 1), .off)
        XCTAssertNil(w.poll(enabled: false, ownerPid: nil, ownerName: nil, selfPid: 1))
        XCTAssertEqual(w.poll(enabled: true, ownerPid: 7, ownerName: "Safari", selfPid: 1),
                       .on("Secure input is on in Safari, so fn can't be heard"))
    }

    func testSecureInputIgnoresShepetalItself() {
        var w = SecureInputWatch()
        XCTAssertNil(w.poll(enabled: true, ownerPid: 1, ownerName: "Shepetal", selfPid: 1))
        XCTAssertFalse(w.isOn)
        XCTAssertFalse(SecureInputWatch.blocks(enabled: true, ownerPid: 1, selfPid: 1))
        XCTAssertTrue(SecureInputWatch.blocks(enabled: true, ownerPid: 2, selfPid: 1))
        XCTAssertFalse(SecureInputWatch.blocks(enabled: false, ownerPid: 2, selfPid: 1))
    }

    func testUnknownOwnerHasGenericWording() {
        var w = SecureInputWatch()
        XCTAssertEqual(w.poll(enabled: true, ownerPid: nil, ownerName: nil, selfPid: 1),
                       .on("Secure input is on in another app, so fn can't be heard"))
        XCTAssertEqual(PasteGate.secureInput(SecureInputWatch.appName(nil)),
                       "Secure input is on in another app. The text is on the clipboard: press ⌘V to paste it.")
    }

    func testLoginStatusMapping() {
        XCTAssertTrue(LoginItemMenu.state(.enabled).checked)
        XCTAssertNil(LoginItemMenu.state(.enabled).message)
        let approval = LoginItemMenu.state(.requiresApproval)
        XCTAssertFalse(approval.checked)
        XCTAssertEqual(approval.message, "Allow Shepetal in System Settings > General > Login Items")
        XCTAssertFalse(LoginItemMenu.state(.notRegistered).checked)
        XCTAssertFalse(LoginItemMenu.state(.notFound).checked)
    }
}
