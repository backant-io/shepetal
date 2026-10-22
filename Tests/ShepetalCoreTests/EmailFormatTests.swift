import XCTest
@testable import ShepetalCore

/// F36: the email layout against the shared vectors (docs/text-rules.md). A case is added to the file, not here,
/// so other platforms are held to it too.
final class EmailFormatTests: XCTestCase {
    struct Case: Decodable { let input, expected, lang, note: String; let signature: String? }

    static let vectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/text-rules/email.json")

    func testSharedVectors() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.vectors))
        XCTAssertGreaterThanOrEqual(cases.count, 30, "the vectors file lost cases")
        for c in cases {
            let out = EmailFormat.apply(c.input, signature: c.signature ?? "")
            XCTAssertEqual(out, c.expected, "\(c.input) (\(c.note))")
            // A dictation is laid out once; laying out the result again must not move or add anything.
            XCTAssertEqual(EmailFormat.apply(out, signature: c.signature ?? ""), out, "running twice changes \(out) (\(c.note))")
        }
    }

    // Rule: never a shepetal-branded line (Wispr's "sent with Flow" is promotion). With no signature set,
    // nothing is added that was not said.
    func testNothingIsAddedThatWasNotSaidOrTyped() {
        let out = EmailFormat.apply("Hi Anna, see you soon. Thanks,")
        XCTAssertFalse(out.lowercased().contains("shepetal"))
        XCTAssertEqual(out.filter(\.isLetter), "HiAnnaSeeyousoonThanks".filter(\.isLetter))
    }

    // The table is Styles' Email category, so Settings' Email style and the layout agree on what is email.
    func testEmailAppsAndWebmail() {
        for id in ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.SparkDesktop", "com.superhuman.electron",
                   "com.mimestream.Mimestream", "org.mozilla.thunderbird", "it.bloop.airmail2"] {
            XCTAssertTrue(EmailFormat.isEmail(bundleId: id, url: ""), id)
        }
        for url in ["https://mail.google.com/mail/u/0/", "https://outlook.live.com/mail/0/", "https://outlook.office.com/mail/",
                    "https://mail.proton.me/u/0/inbox", "https://app.fastmail.com/mail/Inbox"] {
            XCTAssertTrue(EmailFormat.isEmail(bundleId: "com.apple.Safari", url: url), url)
        }
        XCTAssertFalse(EmailFormat.isEmail(bundleId: "com.apple.Notes", url: ""), "Notes keeps the text on one line")
        XCTAssertFalse(EmailFormat.isEmail(bundleId: "com.apple.Safari", url: "https://docs.google.com/document/d/1"))
        XCTAssertFalse(EmailFormat.isEmail(bundleId: "com.apple.Safari", url: "https://proton.me.example.com/"), "look-alike host")
    }

    // A multi-line signature keeps its lines; spaces around it go.
    func testSignatureKeepsItsLines() {
        XCTAssertEqual(EmailFormat.apply("Sounds good. Best,", signature: "  Pavel Hegler\nbackant.io\n"),
                       "Sounds good.\n\nBest,\nPavel Hegler\nbackant.io")
    }
}
