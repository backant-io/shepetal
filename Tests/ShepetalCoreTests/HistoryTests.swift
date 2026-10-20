import SQLite3
import XCTest
@testable import ShepetalCore

final class HistoryTests: XCTestCase {
    var root: URL!
    var dbURL: URL { root.appendingPathComponent("history.sqlite") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func entry(_ id: String, at t: Double = 1_000, text: String = "", raw: String = "") -> HistoryEntry {
        HistoryEntry(id: id, createdAt: Date(timeIntervalSince1970: t), outcome: .inserted, audioPath: "/a/\(id).wav",
                     durationMs: 900, model: "m", rawText: raw, text: text)
    }

    // Pavel's history.sqlite from iteration 1 must open in the new build with every row intact, and keep
    // opening on every later launch.
    func testOldDatabaseUpgradesWithoutLosingRows() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        // The iteration-1 schema, as shipped in #10.
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS history(
              id TEXT PRIMARY KEY, created_at REAL NOT NULL, outcome TEXT NOT NULL, audio_path TEXT NOT NULL,
              duration_ms INTEGER NOT NULL, model TEXT NOT NULL, raw_text TEXT NOT NULL, text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS history_created ON history(created_at);
            INSERT INTO history VALUES ('a', 1000, 'inserted', '/old/a.wav', 1500, 'parakeet', 'um hi there', 'Hi there');
            INSERT INTO history VALUES ('b', 1001, 'too_short', '/old/b.wav', 200, '', '', '');
            INSERT INTO history VALUES ('c', 1002, 'paste_failed', '/old/c.wav', 3000, 'parakeet', 'send it', 'Send it');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let expected = [
            HistoryEntry(id: "c", createdAt: Date(timeIntervalSince1970: 1002), outcome: .pasteFailed, audioPath: "/old/c.wav",
                         durationMs: 3000, model: "parakeet", rawText: "send it", text: "Send it"),
            HistoryEntry(id: "b", createdAt: Date(timeIntervalSince1970: 1001), outcome: .tooShort, audioPath: "/old/b.wav",
                         durationMs: 200),
            HistoryEntry(id: "a", createdAt: Date(timeIntervalSince1970: 1000), outcome: .inserted, audioPath: "/old/a.wav",
                         durationMs: 1500, model: "parakeet", rawText: "um hi there", text: "Hi there"),
        ]
        XCTAssertEqual(try History(path: dbURL).recent(), expected, "first open migrates")
        XCTAssertEqual(expected.map(\.app) + expected.map(\.url), Array(repeating: "", count: 6))
        XCTAssertEqual(try History(path: dbURL).recent(), expected, "second open must not migrate again")
    }

    func testAppBundleAndUrlRoundTrip() throws {
        let history = try History(path: dbURL)
        var e = entry("a", text: "hello")
        e.app = "Safari"; e.bundleId = "com.apple.Safari"; e.url = "https://example.com/a"
        try history.add(e)
        try history.add(entry("b", at: 900))
        XCTAssertEqual(try history.recent(), [e, entry("b", at: 900)])
    }

    // Issue #37: query, fragment, user, password and port can hold secrets; only scheme, host and path are kept.
    func testUrlKeepsOnlySchemeHostAndPath() throws {
        let history = try History(path: dbURL)
        var e = entry("a", text: "hello")
        e.url = "https://alice:hunter2@docs.example.com:8443/d/abc%20def/edit?code=SECRET&state=x#access_token=TOKEN"
        try history.add(e)
        let stored = try XCTUnwrap(history.recent().first).url
        XCTAssertEqual(stored, "https://docs.example.com/d/abc%20def/edit")
        for secret in ["alice", "hunter2", "8443", "SECRET", "state", "TOKEN", "?", "#", "@"] {
            XCTAssertFalse(stored.contains(secret), secret)
        }
        XCTAssertEqual(Browser.historyURL("https://shop.example.com/cart;jsessionid=SECRET?x=1"), "https://shop.example.com/cart")
        XCTAssertEqual(Browser.historyURL("http://example.com"), "http://example.com")
        XCTAssertEqual(Browser.historyURL("file:///Users/me/private.html"), "")
        XCTAssertEqual(Browser.historyURL("about:blank"), "")
        XCTAssertEqual(Browser.historyURL("not a url"), "")
    }

    func testSearchMatchesTextAndRawTextCaseInsensitively() throws {
        let history = try History(path: dbURL)
        try history.add(entry("report", at: 1, text: "Send the Report", raw: "um send the report"))
        try history.add(entry("raw", at: 2, text: "Hello", raw: "hello world"))
        try history.add(entry("other", at: 3, text: "Something else", raw: "something else"))
        XCTAssertEqual(try history.search("REPORT").map(\.id), ["report"])
        XCTAssertEqual(try history.search("World").map(\.id), ["raw"], "raw text counts too")
        XCTAssertEqual(try history.search("e").map(\.id), ["other", "raw", "report"])
        XCTAssertEqual(try history.search("nothing like this"), [])
    }

    // What the user types is literal: '%' and '_' are not wildcards.
    func testSearchEscapesWildcards() throws {
        let history = try History(path: dbURL)
        try history.add(entry("thousand", at: 1, text: "1000 apples"))
        try history.add(entry("percent", at: 2, text: "100% sure"))
        try history.add(entry("snake", at: 3, text: "snake_case"))
        try history.add(entry("x", at: 4, text: "snakeXcase"))
        try history.add(entry("path", at: 5, text: #"C:\temp"#))
        XCTAssertEqual(try history.search("100%").map(\.id), ["percent"])
        XCTAssertEqual(try history.search("_").map(\.id), ["snake"])
        XCTAssertEqual(try history.search("e_c").map(\.id), ["snake"])
        XCTAssertEqual(try history.search(#"\"#).map(\.id), ["path"])
    }

    func testSearchIsNewestFirstAndLimited() throws {
        let history = try History(path: dbURL)
        for i in [2, 0, 4, 1, 3] { try history.add(entry("r\(i)", at: Double(i), text: "note \(i)")) }
        XCTAssertEqual(try history.search("note", limit: 3).map(\.id), ["r4", "r3", "r2"])
        XCTAssertEqual(try history.search("").map(\.id), ["r4", "r3", "r2", "r1", "r0"])
    }

    func testArchivedHiddenUnlessAsked() throws {
        let history = try History(path: dbURL)
        try history.add(entry("keep", at: 1, text: "keep me"))
        try history.add(entry("hide", at: 2, text: "hide me"))
        try history.setArchived("hide", true)
        XCTAssertEqual(try history.search("me").map(\.id), ["keep"])
        let all = try history.search("me", includeArchived: true)
        XCTAssertEqual(all.map(\.id), ["hide", "keep"])
        XCTAssertEqual(all.map(\.archived), [true, false])
        try history.setArchived("hide", false)
        XCTAssertEqual(try history.search("me").map(\.id), ["hide", "keep"])
        XCTAssertThrowsError(try history.setArchived("missing", true))
    }

    // A re-transcription changes what was heard, not when, where or how the recording happened.
    func testUpdateKeepsAudioCreatedAtAndOutcome() throws {
        let history = try History(path: dbURL)
        var original = entry("a", text: "old text", raw: "old raw")
        original.outcome = .pasteFailed
        original.app = "Notes"
        try history.add(original)

        var retried = original
        retried.model = "ggml-large-v3-turbo-q5_0"; retried.rawText = "new raw"; retried.text = "New text"
        retried.createdAt = Date(timeIntervalSince1970: 9_999)
        retried.outcome = .inserted
        retried.audioPath = "/elsewhere.wav"
        retried.durationMs = 1
        retried.app = "Other"
        try history.update(retried)

        var expected = original
        expected.model = retried.model; expected.rawText = "new raw"; expected.text = "New text"
        XCTAssertEqual(try history.recent(), [expected])
        XCTAssertThrowsError(try history.update(entry("missing")))
    }

    func testBrowserBundleIds() {
        for id in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
                   "com.brave.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"] {
            XCTAssertTrue(Browser.contains(id), id)
        }
        for id in ["com.apple.TextEdit", "com.tinyspeck.slackmacgap", "", "com.apple.safari"] {
            XCTAssertFalse(Browser.contains(id), id)
        }
    }
}
