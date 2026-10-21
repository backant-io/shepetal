import XCTest
@testable import ShepetalCore

/// The spoken-date rule against the vectors every platform shares (docs/text-rules.md). A case is added to
/// the file, not here, so Linux and Windows are held to it too.
final class DatesTests: XCTestCase {
    struct Case: Decodable { let input, expected, lang, note: String }

    static let vectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/text-rules/dates.json")

    // Vectors from #176 (spec changes after the #161 reviews) that this port does not pass yet: #189. Each
    // one must still fail, so the list shrinks as the port catches up, and it goes when it is empty.
    static let pending: Set<String> = [
        "Does May July 4th work?",
        "Juli 26.07.2026",
        "March 3-5",
        "Meet on March 5, 10:30.",
        "Am 5. März, 14:30 Uhr",
        "Termin am 3. März, 10.30 Uhr",
        "Am Freitag, den 5. Juni, 14:30 Uhr.",
        "on May 15, 16, and 17.",
        "am sechsundzwanzigsten Juni sechsundzwanzig, also bald",
        "the twenty, sixth of July twenty twenty six",
        "the twenty, first of March",
        "the first of, March",
        "The second may be better.",
        "the first may be fine",
        "Option 2 may work.",
        "Step 3 may fail on Windows.",
        "Chapter 2 may 2026 notes",
        "The first march was long.",
        "MAY 5th",
        "On July 4th two thousand people marched.",
        "On March 3rd 2000 people marched.",
        "am 4. Juli zweitausend Leute",
        "die erste Juli-Woche",
        "the first of May nineteen twenty-first",
        "Mai 26.06.2026",
        "Termin mit August 26.06.26 passt.",
        "Ask June 26.07.26 works.",
        "Tell June May 5th works",
        "Im Juni 1.000 Besucher.",
        "Im März 3,5 Prozent mehr.",
        "In June 1,000 people came.",
        "In May 2,500 users signed up.",
        "In March 3.5 million users joined.",
        "In July 26% of users churned.",
        "June 5-7",
        "July 26/27",
        "am 26. Juni 10:30 Uhr",
        "Am 26. Juni, 14:00 Uhr.",
        "Call me on March 3 10:30 a.m.",
        "am sechs und zwanzigsten Juni",
        "am dreißigsten Juni zweitausend sechs und zwanzig",
        "forty first of March",
        "The first may fail, the second may not.",
        "This is my third September at the company.",
        "My first April in Berlin was cold.",
        "I met Mai 2 weeks ago.",
        "We shipped version 2. March is next.",
        "We need 5. May I ask why?",
        "On March 3 1500 visitors came.",
        "He said \"July 26, 26\".",
        "„Sechsundzwanzigster Juni sechsundzwanzig“",
        "The first of, March.",
        "the 29th of February nineteen hundred",
        "the first of January nineteen hundred.",
        // From the #162 review: Linux and Windows pass these, the Mac rule does not yet (#189).
        "Since May 26.06. we ship.",
        "July 26.07.26",
        "am 31. Dezember neunzehnhundert-neunundneunzig",
        "am ersten März zweitausend-sechsundzwanzig",
        "am 2. Mai zweitausend-und-fünf",
        "Treffen am 5. Juni, 10.30 Uhr",
        "Call me on March 5, 10:30 works.",
        "July 4, 10.5 percent growth",
        "Sessions on March 3, 10, and 17.",
        "On March 3 2000 people marched.",
        "the first of March two thousand people marched",
        "am zweiten Mai zweitausend Leute",
        "We are off August 10-14.",
        "In May 5,000 people came.",
        "July 10:30",
        "at 10:30 July 4th",
        "The first may work, the second may not.",
        "2 may be enough.",
        "the first march was peaceful",
        "I counted 26. May I continue?",
        "The total was 26. March was our best month.",
        "May the fourth be with you.",
        "May the 4th be with you.",
        "Ich habe im Mai 5 Tage Urlaub.",
        "Im Juni 3 Wochen Pause.",
        "die zweite März-Woche",
        "in der ersten Mai-Hälfte",
        "MAY 5TH",
        "He wrote \"July 4th, 26\".",
    ]

    func testSharedVectors() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.vectors))
        XCTAssertGreaterThanOrEqual(cases.count, 80, "the vectors file lost cases")
        for c in cases {
            if Self.pending.contains(c.input) {
                let passes = Dates.apply(c.input) == c.expected && Dates.apply(c.expected) == c.expected
                XCTAssertFalse(passes, "\(c.input) passes now, remove it from pending (#189)")
                continue
            }
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
