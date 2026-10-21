import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F40 on the inserter: a rich snippet is offered as HTML and as plain text in one promised item, so Mail gets the
/// bold and the link and Terminal gets the words. Whichever one the app reads is the paste landing: a check that
/// waited for the plain text would report a paste Mail took as failed and leave the text on the clipboard.
/// A private pasteboard and captured events: nothing is posted to the system.
@MainActor
final class RichPasteTests: XCTestCase {
    var pasteboard: NSPasteboard!
    let html = #"<meta charset="utf-8"><b>Ada</b> Lovelace"#

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    /// At ⌘V the app reads `type` (nil: nothing reads); returns what it got and the offered types.
    func paste(html: String?, reading type: NSPasteboard.PasteboardType?) async -> (Inserter.Result, String?, [NSPasteboard.PasteboardType]) {
        let pb = pasteboard!
        var got: String?, offered: [NSPasteboard.PasteboardType] = []
        let r = await Inserter(pasteboard: pb).insert("Ada Lovelace", html: html, sendPaste: { e in
            guard e.type == .keyDown else { return }
            offered = pb.pasteboardItems?.first?.types ?? []
            if let type { got = pb.string(forType: type) }
        })
        return (r, got, offered)
    }

    func testRichFieldGetsTheHtmlAndThatCountsAsLanded() async {
        let (r, got, offered) = await paste(html: html, reading: .html)
        XCTAssertTrue(r.landed, "Mail reads only the HTML")
        XCTAssertEqual(got, html)
        XCTAssertEqual(Array(offered.prefix(2)), [.html, .string], "the rich type first, the plain fallback next")
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier", "the user's clipboard comes back")
    }

    func testPlainFieldGetsThePlainText() async {
        let (r, got, _) = await paste(html: html, reading: .string)
        XCTAssertTrue(r.landed, "Terminal reads only the plain text")
        XCTAssertEqual(got, "Ada Lovelace", "no markup and no tags in a plain field")
    }

    func testWithoutHtmlOnlyPlainTextIsOffered() async {
        let (r, got, offered) = await paste(html: nil, reading: .html)
        XCTAssertFalse(offered.contains(.html), "a plain dictation never claims to be rich text")
        XCTAssertNil(got)
        XCTAssertFalse(r.landed, "nothing read the text")
    }

    /// Rule 8: a paste nobody took leaves the words on the clipboard for ⌘V, as plain text.
    func testRichPasteNobodyTookLeavesPlainTextOnTheClipboard() async {
        let (r, _, _) = await paste(html: html, reading: nil)
        XCTAssertFalse(r.landed)
        XCTAssertEqual(pasteboard.string(forType: .string), "Ada Lovelace")
    }
}
