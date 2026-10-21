import XCTest
@testable import ShepetalCore

/// F33: Raw per app. Terminal users want "um" and "the fifth of March" left alone while TextEdit keeps the
/// cleanup. Every test uses its own UserDefaults suite, never the app's settings.
final class AppFormatTests: XCTestCase {
    var defaults: UserDefaults!
    var suite: String!
    let terminal = "com.apple.Terminal", textEdit = "com.apple.TextEdit"

    override func setUp() {
        suite = "shepetal-appformat-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    // Nothing set: every app, and no app at all, is Formatted, so the cleanup users have today stays on.
    func testEveryAppIsFormattedUntilTheUserPicksRaw() {
        let format = AppFormat(defaults)
        XCTAssertEqual(format.defaultMode, .formatted)
        XCTAssertEqual([terminal, textEdit, ""].map(format.mode(for:)), [.formatted, .formatted, .formatted])
    }

    // An app's own choice wins over the default either way; Default puts it back on the default.
    func testTheAppsOwnChoiceWinsOverTheDefault() {
        let format = AppFormat(defaults)
        format.set(.raw, for: terminal)
        XCTAssertEqual(format.mode(for: terminal), .raw)
        XCTAssertEqual(format.mode(for: textEdit), .formatted, "only Terminal changed")

        format.defaultMode = .raw
        format.set(.formatted, for: textEdit)
        XCTAssertEqual(format.mode(for: textEdit), .formatted, "Formatted for TextEdit holds while the default is Raw")
        XCTAssertEqual(format.mode(for: "com.apple.Notes"), .raw, "other apps follow the default")
        XCTAssertEqual(format.mode(for: ""), .raw, "no front app follows the default")

        format.set(nil, for: textEdit)
        XCTAssertEqual(format.mode(for: textEdit), .raw, "Default follows the default again")
        format.set(.raw, for: "")
        XCTAssertNil(format.apps[""], "an app without a bundle id is never stored")

        let reopened = AppFormat(defaults)
        XCTAssertEqual(reopened.apps, [terminal: .raw], "the choice is kept for the next launch")
        XCTAssertEqual(reopened.defaultMode, .raw)
    }

    // A value written by hand or by another build drops only itself.
    func testABadStoredValueDropsOnlyItself() {
        defaults.set([terminal: "raw", textEdit: 3, "com.apple.Notes": "loud"], forKey: AppFormat.appsKey)
        defaults.set("loud", forKey: AppFormat.defaultKey)
        let format = AppFormat(defaults)
        XCTAssertEqual(format.apps, [terminal: .raw])
        XCTAssertEqual(format.defaultMode, .formatted)
    }

    // Raw keeps the fillers and the spoken date as heard and never asks the cleanup model; Formatted cleans
    // the same words and writes the date as numbers. The non-speech tag goes in both.
    func testRawKeepsFillersAndSpokenDatesAndSkipsTheModel() {
        let heard = "[BLANK_AUDIO] Um, on the fifth of March, uh, send it to John, I mean Jane."
        let model = FakeCleanupModel { _ in "On the fifth of March, send it to Jane." }
        let raw = AppFormat.finish(heard, mode: .raw, model: model, vocabulary: Vocabulary())
        XCTAssertEqual(raw.text, "Um, on the fifth of March, uh, send it to John, I mean Jane.")
        XCTAssertFalse(raw.usedModel)
        XCTAssertEqual(model.calls, [], "Raw never runs the cleanup model")

        let formatted = AppFormat.finish(heard, mode: .formatted, model: model, vocabulary: Vocabulary())
        XCTAssertEqual(formatted.text, "On 05.03., send it to Jane.")
        XCTAssertTrue(formatted.usedModel)
        XCTAssertEqual(AppFormat.finish(heard, mode: .formatted, model: nil, vocabulary: Vocabulary()).text,
                       Dates.apply(Cleanup.apply("Um, on the fifth of March, uh, send it to John, I mean Jane.")),
                       "rules only without the model")
    }

    // The dictionary fixes what was heard, so a Raw app gets "Kubernetes" as written too.
    func testTheDictionaryRunsInBothModes() {
        let vocabulary = Vocabulary("cube and eighties => Kubernetes\n")
        for mode in FormatMode.allCases {
            XCTAssertEqual(AppFormat.finish("um deploy to cube and eighties", mode: mode, model: nil, vocabulary: vocabulary).text,
                           mode == .raw ? "um deploy to Kubernetes" : "deploy to Kubernetes", "\(mode)")
        }
    }

    // Tags or blank lines only are no speech in Raw too: empty text, so nothing is pasted.
    func testRawWithOnlyTagsOrWhitespaceIsEmpty() {
        for heard in ["[BLANK_AUDIO]", " (silence) ", "\n", ""] {
            XCTAssertEqual(AppFormat.finish(heard, mode: .raw, model: nil, vocabulary: Vocabulary()).text, "", heard)
        }
    }

    // A tag mid-sentence leaves one space in Raw, as the rule cleanup leaves in Formatted, and the dictionary
    // still matches across it.
    func testRawLeavesOneSpaceWhereATagStood() {
        XCTAssertEqual(AppFormat.finish("Send it [BLANK_AUDIO] to (laughs) Jane.", mode: .raw, model: nil, vocabulary: Vocabulary()).text,
                       "Send it to Jane.")
        XCTAssertEqual(AppFormat.finish("deploy to cube [MUSIC] and eighties", mode: .raw, model: nil,
                                        vocabulary: Vocabulary("cube and eighties => Kubernetes\n")).text, "deploy to Kubernetes")
    }
}
