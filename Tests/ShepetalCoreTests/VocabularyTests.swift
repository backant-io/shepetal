import XCTest
@testable import ShepetalCore

/// The personal dictionary (F39). Replacements run on every dictation, so a loose match rewrites words
/// the user never meant ("btw" inside "btwx"), and a regex built from raw text breaks on "c++".
final class VocabularyTests: XCTestCase {
    func testParsesEntriesCommentsAndStars() {
        let v = Vocabulary("""
            # a comment
              GitHub
            *Kubernetes

            omw => on my way
            * pr =>  pull request
            arrow => a => b
            => nothing
            nothing =>
               # indented comment
            C#
            """)
        XCTAssertEqual(v.entries.map(\.spoken), ["GitHub", "Kubernetes", "omw", "pr", "arrow", "C#"])
        XCTAssertEqual(v.entries.map(\.written), ["GitHub", "Kubernetes", "on my way", "pull request", "a => b", "C#"])
        XCTAssertEqual(v.entries.map(\.starred), [false, true, false, true, false, false])
        XCTAssertEqual(Vocabulary(Vocabulary.header).entries, [], "the header is comments only; no entries ship")
    }

    func testReplacementIsWholeWordAndCaseInsensitive() {
        let v = Vocabulary("btw => by the way")
        XCTAssertEqual(v.apply("ok btw, BTW and btwx or abtw."), "ok by the way, By the way and btwx or abtw.")
        XCTAssertEqual(v.apply("Btw I'm late"), "By the way I'm late", "a sentence start keeps its capital")
        XCTAssertEqual(v.apply("snake_btw stays"), "snake_btw stays")
    }

    func testLongestPhraseFirst() {
        let v = Vocabulary("new york => NY\nnew york city => NYC\nny => New York")
        XCTAssertEqual(v.apply("I love new york city and new york"), "I love NYC and NY")
        // One pass: the NY that "new york" became is not replaced again by "ny".
        XCTAssertEqual(v.apply("new  york"), "NY", "whitespace inside a phrase may differ")
    }

    func testRegexCharactersEscaped() {
        let v = Vocabulary("c++ => C++\nnode.js => Node.js\n(beta) => [beta]\n$5 => five dollars")
        XCTAssertEqual(v.apply("I write c++ and node.js (beta) for $5"), "I write C++ and Node.js [beta] for five dollars")
        XCTAssertEqual(v.apply("nodexjs"), "nodexjs", "the dot is a dot, not any character")
    }

    func testVocabularyFixesCasing() {
        let v = Vocabulary("GitHub\niPhone\nVisual Studio Code")
        XCTAssertEqual(v.apply("push it to github from my Iphone in visual studio code"),
                       "push it to GitHub from my iPhone in Visual Studio Code")
        XCTAssertEqual(v.apply("iPhone"), "iPhone", "a vocabulary entry at a sentence start keeps its own casing")
    }

    func testPromptPutsStarredFirstAndCapsAt200() {
        let v = Vocabulary("alpha\n*beta\ngamma => g\n*delta")
        XCTAssertEqual(v.promptTerms, ["beta", "delta", "alpha", "gamma"])
        let many = Vocabulary(((0..<250).map { "w\($0)" } + ["*star"]).joined(separator: "\n"))
        XCTAssertEqual(many.promptTerms.count, Vocabulary.promptLimit)
        XCTAssertEqual(Vocabulary.promptLimit, 200)
        XCTAssertEqual(many.promptTerms.first, "star", "a starred entry at the end of the file still goes first")
    }

    func testEmptyDictionaryChangesNothing() {
        let text = "Exactly what (the model) said, c++ and all."
        XCTAssertEqual(Vocabulary().apply(text), text)
        XCTAssertEqual(Vocabulary("# only comments\n\n").apply(text), text)
        XCTAssertEqual(Vocabulary.load(URL(fileURLWithPath: "/nonexistent/dictionary.txt")).entries, [])
    }

    func testFileIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dictionary.txt")
        func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }

        try Vocabulary.create(url)
        XCTAssertEqual(try mode(), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Vocabulary.header)

        // An editor that saves with the default umask must not leave it readable by others.
        try "GitHub\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(Vocabulary.load(url).entries.map(\.written), ["GitHub"])
        XCTAssertEqual(try mode(), 0o600)

        try Vocabulary.create(url)  // existing file: kept, still 0600
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "GitHub\n")
    }
}
