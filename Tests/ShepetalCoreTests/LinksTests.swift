import XCTest
@testable import ShepetalCore

/// F28: link memory (memory only, newest first, 24 h) and the spoken command that inserts a link.
final class LinksTests: XCTestCase {
    let a = "https://example.com/a", b = "https://example.com/b", c = "http://intranet.local/c?id=7"

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
        XCTAssertEqual(Links.insert("Here it is, insert link.", links: links), "Here it is, \(a)", "a final period after the link goes")
        XCTAssertEqual(Links.insert("Insert link.", links: links), a)
        XCTAssertEqual(Links.insert("Insert the last link", links: links), a)
        XCTAssertEqual(Links.insert("insert last link", links: links), a)
        XCTAssertEqual(Links.insert("The old one: insert link two. Thanks", links: links), "The old one: \(b). Thanks",
                       "a period mid-text stays")
        XCTAssertEqual(Links.insert("insert link number 3", links: links), c)
        XCTAssertEqual(Links.insert("Insert link Three!", links: links), "\(c)!")
        XCTAssertEqual(Links.insert("first insert link one then insert link 2", links: links), "first \(a) then \(b)")
    }

    // Without a model, ordinary speech about links is text.
    func testOrdinarySpeechIsLeftAlone() {
        let links = [a, b]
        for said in ["Send me that link.", "Paste the link here.", "Can you insert the link into the doc?",
                     "Insert links later.", "I'll insert a link.", "insertlink", "Click Insert, then Link.",
                     "Uninsert link"] {
            XCTAssertEqual(Links.insert(said, links: links), said, said)
        }
    }

    // A command whose link is not there stays as said, so nothing silently disappears.
    func testMissingLinkKeepsTheWords() {
        XCTAssertEqual(Links.insert("insert link", links: []), "insert link")
        XCTAssertEqual(Links.insert("insert link three", links: [a, b]), "insert link three")
    }

    // Password managers mark copies Concealed; Shepetal's own pastes are Concealed and Transient.
    func testMarkedItemsAreSkipped() {
        XCTAssertTrue(Links.skips(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(Links.skips(types: ["org.nspasteboard.TransientType", "public.utf8-plain-text"]))
        XCTAssertFalse(Links.skips(types: ["public.utf8-plain-text", "public.url"]))
    }
}
