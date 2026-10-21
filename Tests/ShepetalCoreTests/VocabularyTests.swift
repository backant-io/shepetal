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

    /// Parakeet's keyword rescoring writes a term exactly as it gets it (#30), so the terms keep the file's casing.
    func testPromptTermsKeepTheFileCasing() {
        let v = Vocabulary("useEffect\n*Postgres\nredis => Redis\nGitHub")
        XCTAssertEqual(v.promptTerms, ["Postgres", "useEffect", "redis", "GitHub"])
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

    // MARK: F91: the hub's Dictionary tab edits the file line by line

    /// The user's own comments and layout are theirs: the tab changes one line and leaves the rest alone.
    func testEditChangesOneLineAndKeepsCommentsAndOrder() throws {
        let text = "# my work words\nGitHub\n\n# chat\nbtw => by the way\nKubernetes\n"
        let btw = Vocabulary.Entry(spoken: "btw", written: "by the way")

        XCTAssertEqual(Vocabulary.edit(text, replacing: btw, with: nil),
                       "# my work words\nGitHub\n\n# chat\nKubernetes\n", "remove takes only its own line")
        var starred = btw
        starred.starred = true
        XCTAssertEqual(Vocabulary.edit(text, replacing: btw, with: starred),
                       "# my work words\nGitHub\n\n# chat\n*btw => by the way\nKubernetes\n", "the star stays in place")
        let added = try XCTUnwrap(Vocabulary.edit(text, replacing: nil, with: Vocabulary.Entry(spoken: "pr", written: "pull request")))
        XCTAssertEqual(added, text + "pr => pull request\n", "a new entry goes at the end")
        XCTAssertEqual(Vocabulary(added).entries.last, Vocabulary.Entry(spoken: "pr", written: "pull request"))
        XCTAssertEqual(Vocabulary.edit("GitHub", replacing: nil, with: Vocabulary.Entry(spoken: "C#", written: "C#")),
                       "GitHub\nC#\n", "a file without a final newline gets one before the new line")
        XCTAssertEqual(Vocabulary.edit("", replacing: nil, with: Vocabulary.Entry(spoken: "Shepetal", written: "Shepetal", starred: true)),
                       "*Shepetal\n")
    }

    /// The file is plain text the user can edit at the same time (Edit as text…): an entry that is gone there
    /// must not be written back, or the tab would undo what they just typed.
    func testEditOfAnEntryNoLongerInTheFileChangesNothing() {
        XCTAssertNil(Vocabulary.edit("GitHub\n", replacing: Vocabulary.Entry(spoken: "btw", written: "by the way"), with: nil))
        XCTAssertNil(Vocabulary.edit("*GitHub\n", replacing: Vocabulary.Entry(spoken: "GitHub", written: "GitHub"), with: nil),
                     "a starred line is a different entry from the unstarred one")
    }

    /// Whatever the tab writes reads back as the same entry, so dictation applies exactly what the list showed.
    func testEntryLineRoundTrips() {
        for e in Vocabulary("GitHub\n*Kubernetes\nomw => on my way\n*pr => pull request\narrow => a => b\nC#").entries {
            XCTAssertEqual(Vocabulary(e.line).entries, [e], e.line)
        }
    }

    func testUpdateCreatesTheFileWithItsHeaderAndKeepsItOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dictionary.txt")
        func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }

        let github = Vocabulary.Entry(spoken: "GitHub", written: "GitHub")
        XCTAssertTrue(try Vocabulary.update(url, replacing: nil, with: github))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Vocabulary.header + "GitHub\n",
                       "the first add from the tab still explains the format to someone who opens the file")
        XCTAssertEqual(try mode(), 0o600)

        XCTAssertFalse(try Vocabulary.update(url, replacing: Vocabulary.Entry(spoken: "x", written: "x"), with: nil))
        // Edit as text… in an editor that saves with the default umask, then a change in the tab.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertTrue(try Vocabulary.update(url, replacing: github, with: nil))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Vocabulary.header)
        XCTAssertEqual(try mode(), 0o600, "a write from the tab leaves it owner-only again")
    }

    // MARK: F26: words learned from the user's edits

    private func scratch() throws -> (URL, () throws -> Int, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dictionary.txt")
        let mode = { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
        return (url, mode, { try? FileManager.default.removeItem(at: dir) })
    }

    /// Undo has to give the user their file back exactly: their comments, their layout, a missing final newline.
    func testLearnedBatchIsAppendedUnderAMarkerAndUndoLeavesTheFileAsBefore() throws {
        let (url, mode, cleanup) = try scratch()
        defer { cleanup() }
        let at = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 10, day: 21, hour: 21, minute: 5).date!
        let learned = [Vocabulary.Entry(spoken: "jon", written: "John"), Vocabulary.Entry(spoken: "GitHub", written: "GitHub")]
        for before in ["# mine\nKubernetes\nbtw => by the way", "# mine\nKubernetes\n", "Word\r"] {
            try Data(before.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            let batch = try XCTUnwrap(try Vocabulary.appendLearned(learned, to: url, at: at))
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.hasSuffix("# learned from your edits, 21.10.26 21:05\njon => John\nGitHub\n"), text)
            XCTAssertTrue(try Data(contentsOf: url).starts(with: Data(before.utf8)), "the user's lines stay as they were")
            XCTAssertEqual(Array(Vocabulary.load(url).entries.suffix(2)), learned, "dictation applies them from the next one on")
            XCTAssertEqual(try mode(), 0o600)
            XCTAssertEqual(batch.entries, learned)

            XCTAssertTrue(try Vocabulary.undoLearned(batch, at: url))
            XCTAssertEqual(try Data(contentsOf: url), Data(before.utf8), "byte for byte as before: \(before.debugDescription)")
            XCTAssertEqual(try mode(), 0o600)
            XCTAssertFalse(try Vocabulary.undoLearned(batch, at: url), "a second undo finds nothing to take out")
            XCTAssertEqual(try Data(contentsOf: url), Data(before.utf8))
        }
        try FileManager.default.removeItem(at: url)
        let batch = try XCTUnwrap(try Vocabulary.appendLearned(learned, to: url))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix(Vocabulary.header), "a new file explains its format")
        XCTAssertEqual(try mode(), 0o600)
        XCTAssertTrue(try Vocabulary.undoLearned(batch, at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "there was no file before the batch")
    }

    /// What the user wrote wins: a learned pair never replaces or shadows their entry, and nothing goes in twice.
    func testLearnedNeverOverridesTheUsersEntryAndIsNotAddedTwice() throws {
        let (url, _, cleanup) = try scratch()
        defer { cleanup() }
        let mine = "Jon\ngithub => GitHub\n*Shepetal\n"
        try Data(mine.utf8).write(to: url)
        XCTAssertNil(try Vocabulary.appendLearned([Vocabulary.Entry(spoken: "jon", written: "John"),
                                                   Vocabulary.Entry(spoken: "GitHub", written: "GitHub"),
                                                   Vocabulary.Entry(spoken: "shepetal", written: "Shepetal")], to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), mine, "nothing left to learn: the file is untouched")

        let kube = Vocabulary.Entry(spoken: "cooper netties", written: "Kubernetes")
        let batch = try XCTUnwrap(try Vocabulary.appendLearned([kube, kube, Vocabulary.Entry(spoken: "jon", written: "John")], to: url))
        XCTAssertEqual(batch.entries, [kube], "once, and the user's Jon stays")
        XCTAssertNil(try Vocabulary.appendLearned([Vocabulary.Entry(spoken: "Cooper Netties", written: "Kubernetes")], to: url),
                     "already learned")
        XCTAssertEqual(Vocabulary.load(url).apply("deploy to cooper netties"), "deploy to Kubernetes")
    }

    /// The user may edit the file between the learn and the undo: undo takes only the batch, or nothing.
    func testUndoAfterTheUserEditedTheFile() throws {
        let (url, _, cleanup) = try scratch()
        defer { cleanup() }
        try Data("Kubernetes\n".utf8).write(to: url)
        let batch = try XCTUnwrap(try Vocabulary.appendLearned([Vocabulary.Entry(spoken: "jon", written: "John")], to: url))
        try Vocabulary.update(url, replacing: nil, with: Vocabulary.Entry(spoken: "pr", written: "pull request"))
        XCTAssertTrue(try Vocabulary.undoLearned(batch, at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Kubernetes\npr => pull request\n")

        let again = try XCTUnwrap(try Vocabulary.appendLearned([Vocabulary.Entry(spoken: "jon", written: "John")], to: url))
        try Vocabulary.update(url, replacing: Vocabulary.Entry(spoken: "jon", written: "John"), with: Vocabulary.Entry(spoken: "jon", written: "Jonathan"))
        let edited = try Data(contentsOf: url)
        XCTAssertFalse(try Vocabulary.undoLearned(again, at: url), "the user changed the learned line: it is theirs now")
        XCTAssertEqual(try Data(contentsOf: url), edited)
    }
}
