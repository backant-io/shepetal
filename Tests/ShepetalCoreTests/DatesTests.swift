import XCTest
@testable import ShepetalCore

/// The spoken-date rule against the vectors every platform shares (docs/text-rules.md). A case is added to
/// the file, not here, so Linux and Windows are held to it too.
final class DatesTests: XCTestCase {
    struct Case: Decodable { let input, expected, lang, note: String }

    static let vectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/text-rules/dates.json")

    func testSharedVectors() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.vectors))
        XCTAssertGreaterThanOrEqual(cases.count, 80, "the vectors file lost cases")
        for c in cases {
            XCTAssertEqual(Dates.apply(c.input), c.expected, "\(c.input) (\(c.note))")
            XCTAssertEqual(Dates.apply(c.expected), c.expected, "running twice changes \(c.expected) (\(c.note))")
        }
    }

    // A long hands-free dictation must not slow the paste down.
    func testLongTextIsFast() {
        let text = String(repeating: "We fly out on the twenty sixth of July and back on August 2, maybe. ", count: 80)
        let t0 = Date()
        XCTAssertTrue(Dates.apply(text).hasPrefix("We fly out on 26.07. and back on 02.08., maybe."))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
    }
}
