import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F28's watcher on a private named pasteboard, never the user's clipboard.
@MainActor
final class LinkWatcherTests: XCTestCase {
    var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    func copy(_ s: String, markers: [String] = []) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(s, forType: .string)
        for m in markers { item.setData(Data(), forType: .init(m)) }
        pasteboard.writeObjects([item])
    }

    func testACopiedLinkIsRememberedNewestFirst() async {
        let w = LinkWatcher(pasteboard: pasteboard)
        copy("https://example.com/a"); await w.check()
        copy("https://example.com/b"); await w.check()
        XCTAssertEqual(w.links(), ["https://example.com/b", "https://example.com/a"])
    }

    // What was on the clipboard when the app started is not a copy the user made for "insert link".
    func testTheClipboardAtStartIsNotRemembered() async {
        copy("https://example.com/old")
        let w = LinkWatcher(pasteboard: pasteboard)
        await w.check()
        XCTAssertEqual(w.links(), [])
    }

    // A password manager's copy (Concealed) and a paste in flight (Transient) are never kept, even when they look
    // like a link; plain text is not a link.
    func testMarkedCopiesAndPlainTextAreSkipped() async {
        let w = LinkWatcher(pasteboard: pasteboard)
        copy("https://bank.example.com/reset?token=s3cret", markers: ["org.nspasteboard.ConcealedType"]); await w.check()
        copy("https://example.com/paste", markers: ["org.nspasteboard.TransientType"]); await w.check()
        copy("hunter2"); await w.check()
        XCTAssertEqual(w.links(), [])
    }

    // The system's URL check passes these, so the watcher's own parse must drop them: a sign-in code in the query,
    // and text around a link.
    func testASecretOrTextAroundALinkIsNotRemembered() async {
        let w = LinkWatcher(pasteboard: pasteboard)
        copy("https://example.com/login/callback?code=4f9a2c&state=xyz"); await w.check()
        copy("see https://example.com/a"); await w.check()
        XCTAssertEqual(w.links(), [])
    }

    // Shepetal's own paste is a promised item: an app pulling its data is the paste-landed signal (Inserter), so
    // the watcher must never pull it.
    func testOurOwnPromisedPasteIsNeverPulled() async {
        final class Promise: NSObject, NSPasteboardItemDataProvider {
            var pulled = false
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
                pulled = true
                item.setString("https://example.com/dictated", forType: type)
            }
        }
        let w = LinkWatcher(pasteboard: pasteboard), promise = Promise()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(promise, forTypes: [.string])
        for m in Links.skipTypes { item.setData(Data(), forType: .init(m)) }
        pasteboard.writeObjects([item])
        await w.check()
        XCTAssertFalse(promise.pulled)
        XCTAssertEqual(w.links(), [])
    }

    // Each change is read once.
    func testAnUnchangedPasteboardIsNotReadAgain() async {
        let w = LinkWatcher(pasteboard: pasteboard)
        copy("https://example.com/a"); await w.check()
        await w.check()
        XCTAssertEqual(w.links(), ["https://example.com/a"])
    }

    @available(macOS 15.4, *)
    func testAskOrDenyInSystemSettingsStopsTheReads() {
        XCTAssertTrue(LinkWatcher.mayRead(.default))
        XCTAssertTrue(LinkWatcher.mayRead(.alwaysAllow))
        XCTAssertFalse(LinkWatcher.mayRead(.ask))
        XCTAssertFalse(LinkWatcher.mayRead(.alwaysDeny))
    }
}
