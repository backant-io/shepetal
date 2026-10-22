import XCTest
@testable import ShepetalCore

/// Snippets (F40). One snippets.toml works on the Mac and on Linux, so the format and the matching follow
/// linux/src/vocab.rs; the vectors marked "Linux" are its tests'. A loose match expands a trigger the user never
/// said ("my addressbook"), a second scan expands what was inserted, and markup that leaks through puts `**` into
/// a terminal.
final class SnippetsTests: XCTestCase {
    let address = Snippet(trigger: "my address", expansion: "221B Baker Street\nLondon")

    func v(_ dictionary: String, _ snippets: [(String, String)]) -> Vocabulary {
        Vocabulary(dictionary, snippets: snippets.map { Snippet(trigger: $0.0, expansion: $0.1) })
    }

    /// What dictation does with the text: the whole dictation as a snippet, else the inline pass (Linux's `apply`).
    func dictate(_ vocabulary: Vocabulary, _ text: String) -> String {
        vocabulary.snippet(text)?.rendered.plain ?? vocabulary.apply(text)
    }

    // MARK: the file

    func testParsesTomlPairsAndEscapesAsLinuxWritesThem() {
        // Linux snippets_toml_round_trips: what `shepetal snippet add` writes for this pair.
        XCTAssertEqual(Snippets.parse(#""a \"b\"" = "line1\nline2\t\\ é 🤫 \u0001""#),
                       [Snippet(trigger: "a \"b\"", expansion: "line1\nline2\t\\ é 🤫 \u{1}")])
        XCTAssertEqual(Snippets.parse("\"x\" = \"\\u00e9\" # c\n\"\" = \"y\"\nbad\n\"k\" = \"v\" junk"),
                       [Snippet(trigger: "x", expansion: "é")], "a comment may follow; a blank trigger, a bare word and junk do not count")
        XCTAssertEqual(Snippets.parse("  \"sig\"=\"Ada\"  \n# \"no\" = \"comment\"\n\"bad\" = \"\\q\"\n\"open\" = \"no end\n\"  \" = \"blank\""),
                       [Snippet(trigger: "sig", expansion: "Ada")], "an unknown escape, a missing quote and a blank trigger skip the line")
        XCTAssertEqual(Snippets.parse(Snippets.header), [], "the header is comments only; no snippet ships")
    }

    func testFileIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-snippets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("snippets.toml"), dict = dir.appendingPathComponent("dictionary.txt")
        func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }

        XCTAssertEqual(Snippets.load(url), [], "no file, no snippets")
        try Snippets.create(url)
        XCTAssertEqual(try mode(), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Snippets.header)

        // An editor that saves with the default umask must not leave the user's address readable by others.
        try #""my address" = "221B Baker Street\nLondon""#.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try "btw => by the way\n".write(to: dict, atomically: true, encoding: .utf8)
        let loaded = Vocabulary.load(dict, snippets: url)
        XCTAssertEqual(loaded.snippets, [address])
        XCTAssertEqual(loaded.entries.map(\.written), ["by the way"], "the dictionary loads with it")
        XCTAssertEqual(try mode(), 0o600)

        try Snippets.create(url)  // existing file: kept
        XCTAssertEqual(Snippets.load(url), [address])
        XCTAssertEqual(Vocabulary.load(dict).snippets, [], "without the snippets file, the dictionary alone")
    }

    // MARK: matching

    func testWholeDictationIgnoresCasePunctuationTagsAndFillers() {
        let d = Vocabulary(snippets: [address])
        // Linux whole_dictation_snippet_ignores_case_and_punctuation.
        XCTAssertEqual(dictate(d, "My address."), "221B Baker Street\nLondon")
        XCTAssertEqual(dictate(d, "  my,   ADDRESS!? "), "221B Baker Street\nLondon")
        XCTAssertEqual(dictate(d, "my addresses"), "my addresses")
        // The Mac checks the words as heard, before the cleanup model, so these are the rules' job.
        XCTAssertEqual(d.snippet("Um, my address."), address)
        XCTAssertEqual(d.snippet("[BLANK_AUDIO] my address"), address)
        XCTAssertNil(d.snippet("send my address"), "more than the trigger is a sentence, expanded inline")
        XCTAssertNil(d.snippet("[Music]"))
        XCTAssertNil(Vocabulary(snippets: [Snippet(trigger: "!!", expansion: "x")]).snippet("..."), "nothing said is no trigger")
    }

    func testInlineTriggerExpandsInsideASentence() {
        let d = v("", [("my address", "221B Baker Street")])
        // Linux inline_snippet_expands_inside_a_sentence.
        XCTAssertEqual(dictate(d, "Send it to my address, please."), "Send it to 221B Baker Street, please.")
        XCTAssertEqual(dictate(d, "Send it to My  Address."), "Send it to 221B Baker Street.")
        XCTAssertEqual(dictate(d, "Send it to my addressbook."), "Send it to my addressbook.", "inside a word")
        XCTAssertEqual(dictate(d, "to amy address"), "to amy address", "inside a word on the left")
        XCTAssertEqual(dictate(d, "my\naddress"), "221B Baker Street", "any whitespace between words")
        XCTAssertEqual(v("", [("sig", "ada")]).apply("Sig here"), "ada here", "a snippet is written as stored, never recapitalized")
    }

    func testLongestFirstAndNeverExpandedAgain() {
        let d = v("sig => wrong", [("sig", "sig sig"), ("my sig", "Ada Lovelace"), ("ada", "never")])
        XCTAssertEqual(d.apply("sig"), "sig sig", "the inserted text is not scanned again, and a snippet wins over an entry")
        XCTAssertEqual(d.apply("here is my sig and sig"), "here is Ada Lovelace and sig sig", "the longer trigger first")
        // Linux cli_edits_owner_only_files: the dictionary is written as typed next to a snippet.
        XCTAssertEqual(v("github", [("SIG", "Pavel H")]).apply("github sig"), "github Pavel H")
        XCTAssertEqual(v("my  sig => entry", []).apply("my sig"), "entry", "a phrase stored with two spaces still matches")
    }

    func testUnicodeTriggersAndBoundaries() {
        // Linux unicode_words_and_boundaries, the snippet half.
        let d = v("Zürich", [("эл почта", "me@example.org")])
        XCTAssertEqual(dictate(d, "моя эл почта"), "моя me@example.org")
        XCTAssertEqual(dictate(d, "Эл почта."), "me@example.org")
        XCTAssertEqual(dictate(d, "zürichsee"), "zürichsee", "a non-ASCII letter after it is a word character")
    }

    // MARK: rich text

    /// Bold, italic and links paste as rich text in Mail or Notes; a terminal gets the same words without a `**`.
    func testMarkdownBecomesHtmlAndPlainText() throws {
        let sig = Snippet(trigger: "sig", expansion: "**Ada** *Lovelace*\n[backant.io](https://backant.io/?a=1&b=2) `x<y`")
        let (plain, html) = sig.rendered
        XCTAssertEqual(plain, "Ada Lovelace\nbackant.io x<y", "the newline stays, the markup goes")
        XCTAssertEqual(try XCTUnwrap(html), #"<meta charset="utf-8"><b>Ada</b> <i>Lovelace</i><br>"#
                       + #"<a href="https://backant.io/?a=1&amp;b=2">backant.io</a> <code>x&lt;y</code>"#)
        XCTAssertFalse(html!.contains("font"), "no font: the field keeps its own where the app allows it")
        XCTAssertEqual(Snippets.render("**[both](https://a.b)**").html, #"<meta charset="utf-8"><a href="https://a.b"><b>both</b></a>"#)
        XCTAssertEqual(v("", [("sig", "**Ada** Lovelace")]).apply("thanks, sig"), "thanks, Ada Lovelace",
                       "inline, a snippet goes in as its plain text")
    }

    /// Text without markup is not Markdown to the user: it goes in exactly as stored, with no HTML.
    func testPlainSnippetStaysExactlyAsStored() {
        for text in ["221B Baker Street\nLondon", "2 * 3 * 4 = 24", "snake_case_name", #"C:\Users\ada"#, "a  b\n\n  c", "1. first\n2. second"] {
            let r = Snippets.render(text)
            XCTAssertEqual(r.plain, text, text)
            XCTAssertNil(r.html, text)
        }
    }
}
