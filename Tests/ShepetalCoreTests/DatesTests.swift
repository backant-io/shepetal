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
            if c.input != c.expected {
                XCTAssertEqual(Dates.apply(c.expected), c.expected, "running twice changes \(c.expected) (\(c.note))")
            }
        }
    }

    // A long hands-free dictation must not slow the paste down: the rule reads each word a fixed number of
    // times, so twice the text takes about twice as long. 20 minutes of speech is about 20,000 characters;
    // this is over 100,000, in a debug build.
    func testLongTextIsFast() {
        let line = "We fly out on the twenty sixth of July and back on August 2, maybe. Am 3. März 2026 nicht. "
        let text = String(repeating: line, count: 1200)
        let want = String(repeating: "We fly out on 26.07. and back on 02.08., maybe. Am 03.03.26 nicht. ", count: 1200)
        let t0 = Date()
        XCTAssertEqual(Dates.apply(text), want)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }
}
