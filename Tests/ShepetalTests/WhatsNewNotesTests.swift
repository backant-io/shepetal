import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// The release notes behind What's new…: a build's version always has its notes, so the update hint never
/// points at a window that says nothing about the update.
@MainActor
final class WhatsNewNotesTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// `VERSION=${VERSION:-0.1.0}` style defaults: what a build gets when no VERSION is given.
    private func defaultVersion(_ script: String) throws -> String {
        let text = try String(contentsOf: Self.repo.appendingPathComponent(script), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"^\w*VERSION=\$\{VERSION:-([0-9.]+)\}"#, options: .anchorsMatchLines)
        let ns = text as NSString
        let m = try XCTUnwrap(re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), "no default VERSION in \(script)")
        return ns.substring(with: m.range(at: 1))
    }

    func testTheDefaultBuildVersionHasReleaseNotes() throws {
        let versions = WhatsNewWindow.notes.map(\.version)
        for script in ["scripts/make-app.sh", "scripts/make-dmg.sh"] {
            let v = try defaultVersion(script)
            XCTAssertTrue(versions.contains(v), "\(script) builds \(v), which has no entry in WhatsNewWindow.notes")
        }
    }

    /// The window reads top down as this version, then the older ones.
    func testNotesAreNewestFirstWithDDMMYYDates() {
        let notes = WhatsNewWindow.notes
        XCTAssertFalse(notes.isEmpty)
        for (newer, older) in zip(notes, notes.dropFirst()) {
            XCTAssertTrue(WhatsNew.isNewer(newer.version, than: older.version), "\(newer.version) is listed above \(older.version)")
        }
        let ddMMyy = DateFormatter()  // strict, and it must print the date back as written: 10.20.26 or 1.10.26 fail
        ddMMyy.locale = Locale(identifier: "en_US_POSIX")
        ddMMyy.dateFormat = "dd.MM.yy"
        ddMMyy.isLenient = false
        for n in notes {
            XCTAssertEqual(ddMMyy.date(from: n.date).map(ddMMyy.string(from:)), n.date, "\(n.version): \(n.date) is not DD.MM.YY")
            XCTAssertFalse(n.lines.isEmpty, "\(n.version) has no lines")
        }
    }

    func testTheWindowTextHasEveryVersionNewestFirst() {
        let text = WhatsNewWindow.text().string
        let headings = WhatsNewWindow.notes.map { "\($0.version) · \($0.date)" }
        XCTAssertTrue(text.hasPrefix(headings[0]))
        let at = headings.compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(at.count, headings.count)
        XCTAssertEqual(at, at.sorted())
        for line in WhatsNewWindow.notes.flatMap(\.lines) { XCTAssertTrue(text.contains("• \(line)")) }
    }

    /// The app delegate cannot run in a test, so this pins the What's new wiring in App.swift by its source.
    /// atLaunch() must look for history.sqlite before Pipeline creates it, or every update from 0.1.0 is silent.
    /// The update hint comes before Account.shared.start, so the account and permission hints replace it.
    /// What's new… is on Home (the 🤫 menu stays at its 12 items), and the hint says so.
    func testTheAppChecksForAnUpdateBeforePipelineAndHintsBeforeTheAccount() throws {
        let app = try AppSource.code("App.swift")
        let launch = try AppSource.body(of: "func applicationDidFinishLaunching(", in: app)
        func at(_ line: String) throws -> String.Index {
            try XCTUnwrap(launch.range(of: line), "applicationDidFinishLaunching: \(line)").lowerBound
        }
        XCTAssertLessThan(try at("let updated = WhatsNewWindow.atLaunch()"), try at("Pipeline(pasteboard: .general)"),
                          "atLaunch() must run before Pipeline creates history.sqlite")
        XCTAssertLessThan(try at("if let updated { indicator.show(WhatsNew.hint(updated), seconds: 6) }"),
                          try at("Account.shared.start("), "the account hint must replace the update hint, not the reverse")
        XCTAssertTrue(app.contains("openWhatsNew: { [weak self] in self?.openWhatsNew() },"), "the Hub gets the window")
        let home = try AppSource.body(of: "private struct HomeTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(home.contains("Button(\"What's new…\", action: model.openWhatsNew)"), "What's new… is not on Home")
        XCTAssertTrue(WhatsNew.hint("0.1.1").contains("on Home"), "the hint names where the notes are")
    }
}
