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

    // The system's URL check passes these, so the watcher's own parse must drop them: a link with a sign-in code
    // in the query only blocks the newest place (nil), and text around a link is not a link.
    func testASecretOrTextAroundALinkIsNotRemembered() async {
        let w = LinkWatcher(pasteboard: pasteboard)
        copy("https://example.com/login/callback?code=4f9a2c&state=xyz"); await w.check()
        copy("see https://example.com/a"); await w.check()
        XCTAssertEqual(w.links(), [nil])
    }

    // Shepetal's own paste is a promised item: an app pulling its data is the paste-landed signal (Inserter), so
    // the watcher must never pull it.
    func testOurOwnPromisedPasteIsNeverPulled() async {
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

    // `.default` is read, and on an enforcing macOS that first read raises the paste alert (NSPasteboard.h), after
    // which the state is `.ask`. Ask and Deny stop the reads.
    @available(macOS 15.4, *)
    func testAskOrDenyInSystemSettingsStopsTheReads() {
        XCTAssertTrue(LinkWatcher.allows(.default))
        XCTAssertTrue(LinkWatcher.allows(.alwaysAllow))
        XCTAssertFalse(LinkWatcher.allows(.ask))
        XCTAssertFalse(LinkWatcher.allows(.alwaysDeny))
    }

    /// Writes a link as promised data, and says whether anyone pulled it, which is what a read is.
    final class Promise: NSObject, NSPasteboardItemDataProvider {
        var pulled = false
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            pulled = true
            item.setString("https://example.com/promised", forType: type)
        }
    }

    func promise() -> Promise {
        let promise = Promise(), item = NSPasteboardItem()
        pasteboard.clearContents()
        item.setDataProvider(promise, forTypes: [.string])
        pasteboard.writeObjects([item])
        return promise
    }

    // Review of #250: the macOS 15.4+ gates in check itself. When reads are not allowed, or the system's check says
    // the copy is not a web URL, nothing is read at all, so no paste alert. With both open the same copy is read,
    // so the promise does tell a read.
    func testTheGatesStopTheReadItself() async {
        for (allowed, url) in [(false, true), (true, false), (true, true)] {
            let w = LinkWatcher(pasteboard: pasteboard)
            w.mayRead = { allowed }
            w.looksLikeURL = { url }
            let p = promise()
            await w.check()
            XCTAssertEqual(p.pulled, allowed && url, "mayRead \(allowed), looksLikeURL \(url)")
            XCTAssertEqual(w.links(), allowed && url ? ["https://example.com/promised"] : [])
        }
    }

    // A copy made while the system checked the one before is not read on that poll: it was not checked. The next
    // poll checks it.
    func testACopyDuringTheURLCheckWaitsForTheNextPoll() async {
        let w = LinkWatcher(pasteboard: pasteboard)
        var checks = 0
        w.looksLikeURL = { [self] in
            checks += 1
            if checks == 1 { copy("https://example.com/unchecked") }
            return true
        }
        copy("https://example.com/a"); await w.check()
        XCTAssertEqual(w.links(), [])
        await w.check()
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(w.links(), ["https://example.com/unchecked"])
    }

    // The real gates on this Mac: a named pasteboard is always allowed (NSPasteboard.h), and the system tells a
    // link from other text.
    func testTheSystemCheckTellsALinkFromText() async {
        let w = LinkWatcher(pasteboard: pasteboard)
        XCTAssertTrue(w.mayRead())
        guard #available(macOS 15.4, *) else { return }
        copy("hunter2")
        let text = await w.looksLikeURL()
        XCTAssertFalse(text)
        copy("https://example.com/a")
        let link = await w.looksLikeURL()
        XCTAssertTrue(link)
    }
}
