import AppKit
import SwiftUI
import XCTest
import ShepetalCore
@testable import Shepetal

/// F118: the share card is the user's own numbers, made on this Mac. It must be a real image at the size posts
/// show uncropped, go only where the user clicked (a pasteboard, a file, the browser), and never upload or open
/// anything by itself. Tests use a private pasteboard and a spy for the browser.
@MainActor
final class ShareCardTests: XCTestCase {
    let stats = ShareStats(words: 12_340, wpm: 142, streak: 7)

    /// A PNG of 1200 × 630 pixels. Two renders of one card are not always the same bytes, so this checks the image.
    func assertCard(_ png: Data?, file: StaticString = #filePath, line: UInt = #line) throws {
        let png = try XCTUnwrap(png, "no PNG", file: file, line: line)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature", file: file, line: line)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png), file: file, line: line)
        XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [1200, 630], file: file, line: line)
    }

    func testTheCardIsA1200By630PNG() throws {
        try assertCard(ShareCard.png(stats))
    }

    // A blank card would still be a valid PNG: the numbers must change the pixels. The first render in a process can
    // differ from later ones, so one render warms up and the same card must then give the same pixels; only then
    // does a different count prove the number is drawn, whatever ran before this test.
    func testTheNumbersAreDrawn() throws {
        func pixels(_ s: ShareStats) throws -> Data {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ShareCard.png(s))))
            return Data(bytes: try XCTUnwrap(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
        }
        _ = ShareCard.png(stats)
        let card = try pixels(stats)
        XCTAssertEqual(card, try pixels(stats), "the same card renders the same")
        XCTAssertNotEqual(card, try pixels(ShareStats(words: 99, wpm: 142, streak: 7)))
    }

    func testCopyPutsThePNGOnThePasteboardItIsGiven() throws {
        let pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let general = NSPasteboard.general.changeCount  // read only: the user's clipboard is never written here
        let note = ShareActions(stats: stats, pasteboard: pasteboard, open: { XCTFail("Copy opened \($0)") }).copy()
        XCTAssertEqual(note, "Copied: paste it into a message or a post")
        try assertCard(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff), "for apps that read only TIFF")
        XCTAssertEqual(NSPasteboard.general.changeCount, general)
    }

    func testSaveWritesThePNG() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-share-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        _ = ShareActions(stats: stats, pasteboard: pasteboard, open: { _ in }).save(to: url)
        try assertCard(try Data(contentsOf: url))
    }

    func testThePostCarriesTheNumbersInOurWords() throws {
        let url = ShareCard.postURL(stats)
        XCTAssertEqual(url.host, "x.com")
        let text = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value)
        XCTAssertEqual(text, "I've dictated \(12_340.formatted()) words with shepetal at 142 words per minute, on a 7-day streak. "
                           + "Voice dictation that never leaves my Mac: https://shepetal.app")
        XCTAssertFalse(ShareStats(words: 5, wpm: 90, streak: 0).text.contains("streak"), "no streak is left out")
    }

    // Showing the sheet opens nothing; only Post does, once, with the prefilled post.
    func testNothingOpensWithoutTheClick() throws {
        var opened: [URL] = []
        let pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let actions = ShareActions(stats: stats, pasteboard: pasteboard, open: { opened.append($0) })
        let sheet = ImageRenderer(content: ShareStatsSheet(actions: actions, close: {}))
        XCTAssertNotNil(sheet.cgImage, "the sheet's body was built")
        XCTAssertEqual(opened, [])
        actions.post()
        XCTAssertEqual(opened, [ShareCard.postURL(stats)])
    }

    func testStatsComeFromDeliveredDictations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try History(path: root.appendingPathComponent("history.sqlite"))
        let today = Date()
        func add(_ id: String, _ outcome: Outcome, daysAgo: Double, words: Int, ms: Int) throws {
            let text = Array(repeating: "word", count: words).joined(separator: " ")
            try history.add(HistoryEntry(id: id, createdAt: today.addingTimeInterval(-daysAgo * 86_400), outcome: outcome,
                                         audioPath: "/a/\(id).wav", durationMs: ms, rawText: text, text: text))
        }
        try add("a", .inserted, daysAgo: 0, words: 80, ms: 40_000)
        try add("b", .inserted, daysAgo: 1, words: 40, ms: 20_000)
        try add("c", .cancelled, daysAgo: 2, words: 500, ms: 60_000)
        XCTAssertEqual(try ShareStats(history, today: today), ShareStats(words: 120, wpm: 120, streak: 2))
    }
}
