import XCTest
@testable import ShepetalCore

/// F28: link memory (memory only, newest first, 24 h) and the spoken command that inserts a link.
final class LinksTests: XCTestCase {
    let a = "https://example.com/a", b = "https://example.com/b", c = "http://intranet.local/c?id=7"

    /// Without a model the text is what was said, so every command in it was said.
    func insert(_ text: String, links: [String]) -> String { Links.insert(text, links: links, said: text) }

    // Only a whole http(s) URL is a link. Text around it, other schemes, and a URL carrying a password are not.
    func testOnlyAWholeWebURLIsKept() {
        XCTAssertEqual(Links.url(from: "  https://example.com/a?b=1#c\n"), "https://example.com/a?b=1#c")
        XCTAssertEqual(Links.url(from: "HTTP://Example.com"), "HTTP://Example.com")
        XCTAssertEqual(Links.url(from: "http://localhost:3000/x"), "http://localhost:3000/x")
        for no in ["", "example.com", "www.example.com", "see https://example.com", "https://example.com and more",
                   "ftp://example.com/f", "file:///Users/pavel/secret.txt", "mailto:anna@example.com", "https://",
                   "https://user:hunter2@example.com/", "https://user@example.com/", "javascript:alert(1)",
                   "correct horse battery staple"] {
            XCTAssertNil(Links.url(from: no), no)
        }
    }

    // A link copied again moves to the front instead of taking a second place.
    func testDedupeMovesToTheFront() {
        var m = LinkMemory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(a, at: t); m.add(b, at: t + 1); m.add(a, at: t + 2)
        XCTAssertEqual(m.links(now: t + 3), [a, b])
    }

    // Links last 24 hours from their last copy, then are gone.
    func testExpiry() {
        var m = LinkMemory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(a, at: t); m.add(b, at: t + 3600)
        XCTAssertEqual(m.links(now: t + LinkMemory.lifetime - 1), [b, a])
        XCTAssertEqual(m.links(now: t + LinkMemory.lifetime), [b], "a is 24 h old")
        XCTAssertEqual(m.links(now: t + 3600 + LinkMemory.lifetime), [])
        m.add(a, at: t + LinkMemory.lifetime - 10)  // copied again: its 24 hours start over
        XCTAssertEqual(m.links(now: t + 2 * LinkMemory.lifetime - 11), [a])
    }

    // At most 20: the oldest goes first.
    func testCapacity() {
        var m = LinkMemory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<25 { m.add("https://example.com/\(i)", at: t + Double(i)) }
        let kept = m.links(now: t + 30)
        XCTAssertEqual(kept.count, LinkMemory.capacity)
        XCTAssertEqual(kept.first, "https://example.com/24")
        XCTAssertEqual(kept.last, "https://example.com/5")
    }

    func testCommandsInsertTheirLink() {
        let links = [a, b, c]
        XCTAssertEqual(insert("Here it is, insert link.", links: links), "Here it is, \(a)", "a final period after the link goes")
        XCTAssertEqual(insert("Insert link.", links: links), a)
        XCTAssertEqual(insert("Insert the last link", links: links), a)
        XCTAssertEqual(insert("insert last link", links: links), a)
        XCTAssertEqual(insert("The old one: insert link two. Thanks", links: links), "The old one: \(b). Thanks",
                       "a period mid-text stays")
        XCTAssertEqual(insert("insert link number 3", links: links), c)
        XCTAssertEqual(insert("Insert link Three!", links: links), "\(c)!")
        XCTAssertEqual(insert("first insert link one then insert link 2", links: links), "first \(a) then \(b)")
    }

    // Without a model, ordinary speech about links is text.
    func testOrdinarySpeechIsLeftAlone() {
        let links = [a, b]
        for said in ["Send me that link.", "Paste the link here.", "Can you insert the link into the doc?",
                     "Insert links later.", "I'll insert a link.", "insertlink", "Click Insert, then Link.",
                     "Uninsert link"] {
            XCTAssertEqual(insert(said, links: links), said, said)
        }
    }

    // Security review: only a command the user said pastes a link. The cleanup model's text, or the field around the
    // cursor it read (F24), adds none, no second one, and no other one than the user named.
    func testOnlyACommandTheUserSaidInsertsALink() {
        let links = [a, b]
        XCTAssertEqual(Links.insert("Here it is, insert link.", links: links, said: "Here it is."), "Here it is, insert link.")
        XCTAssertEqual(Links.insert("insert link and insert link", links: links, said: "insert link and"), "\(a) and insert link")
        XCTAssertEqual(Links.insert("insert link two", links: links, said: "insert link"), "insert link two")
        XCTAssertEqual(Links.insert("Insert link two.", links: links, said: "insert link number 2"), b, "the same link, said another way")
    }

    // Security review: a link with a secret in its query or fragment (a reset token, a sign-in code, a signed or
    // OAuth URL) is never kept, so it can never be pasted. Ordinary parameters and anchors are kept.
    func testALinkCarryingASecretIsNotKept() {
        for no in ["https://example.com/reset?token=s3cret", "https://example.com/callback?state=x&code=abc",
                   "https://bucket.s3.amazonaws.com/f.pdf?X-Amz-Signature=abc", "https://api.example.com/v1?apiKey=abc",
                   "https://example.com/?SESSIONID=1", "https://example.com/login?password=x", "https://example.com/?auth=x",
                   "https://example.com/done#access_token=abc&token_type=bearer"] {
            XCTAssertNil(Links.url(from: no), no)
        }
        for yes in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://example.com/report?id=7",
                    "https://docs.example.com/api#keys"] {
            XCTAssertEqual(Links.url(from: yes), yes)
        }
    }

    // Review of #250: a copied link that is never offered still takes the newest place, so "insert link" stays as
    // words and never pastes a different link, copied up to 24 h before. Zoom and Dropbox share links carry
    // "pwd" and "rlkey". Copying it again (the Inserter's restore) keeps one place; text that is not a link
    // changes nothing.
    func testALinkNeverOfferedBlocksTheNewestPlace() {
        var m = LinkMemory()
        let t = Date(timeIntervalSince1970: 1_000_000), zoom = "https://us02web.zoom.us/j/123?pwd=abc"
        m.add(a, at: t); m.add(zoom, at: t + 1); m.add("see \(b)", at: t + 2); m.add("hunter2", at: t + 3)
        m.add(zoom, at: t + 4)
        let links = m.links(now: t + 5)
        XCTAssertEqual(links, [nil, a])
        XCTAssertEqual(Links.insert("Join here: insert link.", links: links, said: "Join here: insert link."), "Join here: insert link.")
        XCTAssertEqual(Links.insert("insert link two", links: links, said: "insert link two"), a)
        m.add("https://www.dropbox.com/scl/fi/x/f.pdf?rlkey=abc&dl=0", at: t + 6); m.add(b, at: t + 7)
        XCTAssertEqual(m.links(now: t + 8), [b, nil, nil, a], "a different blocked link takes its own place")
    }

    // A command whose link is not there stays as said, so nothing silently disappears.
    func testMissingLinkKeepsTheWords() {
        XCTAssertEqual(insert("insert link", links: []), "insert link")
        XCTAssertEqual(insert("insert link three", links: [a, b]), "insert link three")
    }

    // Password managers mark copies Concealed; Shepetal's own pastes are Concealed and Transient.
    func testMarkedItemsAreSkipped() {
        XCTAssertTrue(Links.skips(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(Links.skips(types: ["org.nspasteboard.TransientType", "public.utf8-plain-text"]))
        XCTAssertFalse(Links.skips(types: ["public.utf8-plain-text", "public.url"]))
    }
}
