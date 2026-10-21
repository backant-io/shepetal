import XCTest
@testable import ShepetalCore

/// F100: a 3 s hint next to 🤫 that the user missed can be read later on Home. The list must stay small (memory
/// only), show the newest first, and not fill up with one hint repeated, so older different notices stay readable.
final class NoticeLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNewestFirst() {
        var log = NoticeLog()
        log.append("Cancelled", at: t0)
        log.append(Hint.nothingToPaste, at: t0 + 5)
        XCTAssertEqual(log.newestFirst, [.init(text: Hint.nothingToPaste, time: t0 + 5), .init(text: "Cancelled", time: t0)])
    }

    func testKeepsOnlyTheLast50() {
        var log = NoticeLog()
        for i in 0..<120 { log.append("notice \(i)", at: t0 + Double(i)) }
        XCTAssertEqual(log.newestFirst.count, 50)
        XCTAssertEqual(log.newestFirst.first?.text, "notice 119")
        XCTAssertEqual(log.newestFirst.last?.text, "notice 70", "the oldest go first")
    }

    // Pressing fn too briefly five times in a row is one notice, at the last press, so it cannot push the
    // paste-to-clipboard hint out of sight. The same text after another notice is a new row.
    func testConsecutiveDuplicatesCollapseToTheLatest() {
        var log = NoticeLog()
        log.append(PasteGate.focusMoved, at: t0)
        for i in 1...5 { log.append(Hint.shortPress, at: t0 + Double(i)) }
        XCTAssertEqual(log.newestFirst, [.init(text: Hint.shortPress, time: t0 + 5), .init(text: PasteGate.focusMoved, time: t0)])
        log.append(PasteGate.focusMoved, at: t0 + 6)
        log.append(Hint.shortPress, at: t0 + 7)
        XCTAssertEqual(log.newestFirst.map(\.text), [Hint.shortPress, PasteGate.focusMoved, Hint.shortPress, PasteGate.focusMoved])
    }

    // Product rule: dates are DD.MM.YY, whatever the Mac's locale.
    func testTimeIsDDMMYY() {
        XCTAssertEqual(NoticeLog.time(t0, timeZone: TimeZone(identifier: "UTC")!), "15.01.27 08:00")
    }
}
