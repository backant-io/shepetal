import XCTest
@testable import ShepetalCore

/// F37: one writing style per kind of app, as rules. Formal is what dictation wrote before styles, so nothing
/// changes until the user picks a style; the other styles change only casing and punctuation, never words.
final class StylesTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "shepetal-styles-test-\(UUID().uuidString)"  // never the app's own defaults
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    /// The desktop apps the triage names land in their category, matched by bundle id in any case.
    func testAppsMapToTheirCategory() {
        let want: [(String, AppCategory)] = [
            ("com.tinyspeck.slackmacgap", .work), ("com.microsoft.teams2", .work),
            ("com.apple.mail", .email), ("com.microsoft.Outlook", .email), ("com.superhuman.electron", .email),
            ("com.readdle.SparkDesktop", .email),
            ("com.apple.MobileSMS", .personal), ("net.whatsapp.WhatsApp", .personal), ("ru.keepcoder.Telegram", .personal),
            ("org.whispersystems.signal-desktop", .personal), ("com.tencent.xinWeChat", .personal),
            ("com.facebook.archon.developerID", .personal),
            ("com.apple.TextEdit", .other), ("com.apple.Notes", .other), ("", .other),
        ]
        for (id, category) in want { XCTAssertEqual(Styles.category(bundleId: id, url: ""), category, id) }
    }

    /// In a browser the page decides: Slack, Teams, Gmail and Outlook on the web get the app's style, any other
    /// page is Other. A host only counts as itself or a subdomain, so look-alike hosts stay Other.
    func testBrowserPagesMapByHost() {
        let chrome = "com.google.Chrome"
        let want: [(String, AppCategory)] = [
            ("https://app.slack.com/client/T1/C2", .work), ("https://acme.slack.com/archives/C2", .work),
            ("https://teams.microsoft.com/v2/", .work),
            ("https://mail.google.com/mail/u/0/", .email), ("https://outlook.office.com/mail/", .email),
            ("https://outlook.live.com/mail/0/", .email), ("https://outlook.cloud.microsoft/mail/", .email),
            ("https://web.whatsapp.com/", .personal), ("https://www.messenger.com/t/1", .personal),
            ("https://news.ycombinator.com/", .other), ("https://notslack.com/", .other),
            ("https://slack.com.evil.example/", .other), ("", .other),
        ]
        for (url, category) in want { XCTAssertEqual(Styles.category(bundleId: chrome, url: url), category, url) }
    }

    /// The default is Formal everywhere, and Formal returns the text exactly as it came in.
    func testFormalIsTheDefaultAndChangesNothing() {
        for id in ["com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.MobileSMS", "com.apple.TextEdit"] {
            XCTAssertEqual(Styles.chosen(bundleId: id, url: "", defaults), .formal, id)
        }
        let said = "Hey Anna, the build is green. I will merge it at 5 p.m. "
        XCTAssertEqual(Styles.apply(.formal, to: said), said)
    }

    /// A pick is per category and read back from defaults; an unknown stored value falls back to Formal.
    func testThePickedStyleIsReadPerCategory() {
        defaults.set(Style.casual.rawValue, forKey: Styles.key(.work))
        defaults.set(Style.veryCasual.rawValue, forKey: Styles.key(.personal))
        defaults.set("loud", forKey: Styles.key(.email))
        XCTAssertEqual(Styles.chosen(bundleId: "com.tinyspeck.slackmacgap", url: "", defaults), .casual)
        XCTAssertEqual(Styles.chosen(bundleId: "com.google.Chrome", url: "https://app.slack.com/client", defaults), .casual)
        XCTAssertEqual(Styles.chosen(bundleId: "com.apple.MobileSMS", url: "", defaults), .veryCasual)
        XCTAssertEqual(Styles.chosen(bundleId: "com.apple.mail", url: "", defaults), .formal, "unknown value")
        XCTAssertEqual(Styles.chosen(bundleId: "com.apple.TextEdit", url: "", defaults), .formal, "Other was never picked")
    }

    /// Casual keeps the capitals, drops the comma after an opening greeting or interjection and the final
    /// period, and leaves every other comma and period.
    func testCasualDropsTheFinalPeriodAndOpeningCommas() {
        XCTAssertEqual(Styles.apply(.casual, to: "Hey Anna, the build is green. Oh, and I fixed the test, finally."),
                       "Hey Anna the build is green. Oh and I fixed the test, finally")
        XCTAssertEqual(Styles.apply(.casual, to: "Thanks, see you tomorrow."), "Thanks see you tomorrow")
        XCTAssertEqual(Styles.apply(.casual, to: "The report, as promised, is done."), "The report, as promised, is done")
    }

    /// Very casual is all lowercase, "I" too, with the casual commas and no final period.
    func testVeryCasualIsLowercaseWithoutTheFinalPeriod() {
        XCTAssertEqual(Styles.apply(.veryCasual, to: "Hey Anna, I think I can make it. See you at Joe's."),
                       "hey anna i think i can make it. see you at joe's")
    }

    /// Excited ends the last sentence in "!", and only the last one.
    func testExcitedEndsTheLastSentenceWithAnExclamation() {
        XCTAssertEqual(Styles.apply(.excited, to: "We shipped it. The demo went well."), "We shipped it. The demo went well!")
        XCTAssertEqual(Styles.apply(.excited, to: "We shipped it"), "We shipped it!")
        XCTAssertEqual(Styles.apply(.excited, to: "Hey, we shipped it."), "Hey, we shipped it!", "commas stay")
    }

    /// A question stays a question in every style, and a sentence that already ends in "!" or "…" keeps it.
    func testQuestionsAndOtherEndingsAreKept() {
        for style in Style.allCases {
            XCTAssertTrue(Styles.apply(style, to: "Can you send it today?").hasSuffix("today?"), "\(style)")
            XCTAssertTrue(Styles.apply(style, to: "Done. Are you free later?").hasSuffix("later?"), "\(style)")
            XCTAssertTrue(Styles.apply(style, to: "Let me think...").hasSuffix("..."), "\(style)")
        }
        XCTAssertEqual(Styles.apply(.casual, to: "That is great!"), "That is great!")
    }

    /// URLs and email addresses keep their case and dots; only the sentence's own final period goes.
    func testURLsAreUntouched() {
        XCTAssertEqual(Styles.apply(.veryCasual, to: "The notes are at https://Example.com/Docs/Q3 for Anna."),
                       "the notes are at https://Example.com/Docs/Q3 for anna")
        XCTAssertEqual(Styles.apply(.veryCasual, to: "Write to Anna.Berg@Example.com."), "write to Anna.Berg@Example.com")
        XCTAssertEqual(Styles.apply(.casual, to: "Open github.com/Backant-IO/shepetal."), "Open github.com/Backant-IO/shepetal")
        XCTAssertEqual(Styles.apply(.excited, to: "Open github.com/Backant-IO/shepetal"), "Open github.com/Backant-IO/shepetal",
                       "no ! glued to a link")
    }

    /// A final dot that belongs to an abbreviation or a DD.MM. date stays; decimals keep their point.
    func testAbbreviationsDatesAndDecimalsKeepTheirDots() {
        XCTAssertEqual(Styles.apply(.casual, to: "See you at 5 p.m."), "See you at 5 p.m.")
        XCTAssertEqual(Styles.apply(.casual, to: "Bring cables, adapters etc."), "Bring cables, adapters etc.")
        XCTAssertEqual(Styles.apply(.casual, to: "Wir treffen uns am 01.03."), "Wir treffen uns am 01.03.")
        XCTAssertEqual(Styles.apply(.casual, to: "Wir treffen uns am 26.07.26."), "Wir treffen uns am 26.07.26")
        XCTAssertEqual(Styles.apply(.casual, to: "It costs 19.99."), "It costs 19.99")
        XCTAssertEqual(Styles.apply(.veryCasual, to: "It costs 1,250.50 in total."), "it costs 1,250.50 in total")
        XCTAssertEqual(Styles.apply(.excited, to: "It costs 19.99."), "It costs 19.99!")
        XCTAssertEqual(Styles.apply(.excited, to: "See you at 5 p.m."), "See you at 5 p.m.!")
    }

    /// The pipeline runs the style before the personal dictionary, so a dictionary word keeps its casing in
    /// Very casual while everything around it is lowercase.
    func testDictionaryCasingSurvivesVeryCasual() {
        let dictionary = Vocabulary("GitHub\nbtw => by the way\n")
        let styled = Styles.apply(.veryCasual, to: "I pushed it to GitHub. Btw, it builds.")
        XCTAssertEqual(dictionary.apply(styled), "i pushed it to GitHub. by the way, it builds")
    }
}
