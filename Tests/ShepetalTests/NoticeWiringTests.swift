import XCTest
@testable import Shepetal

/// F100: the Hub's Home tab lists what 🤫 showed. The app delegate and the Hub window cannot run in a test, so this
/// pins the wiring by its source: App hands the Hub the indicator's log, and Home lists it.
final class NoticeWiringTests: XCTestCase {
    func testHubGetsTheIndicatorsNotices() throws {
        XCTAssertTrue(try AppSource.code("App.swift").contains("notices: { [weak self] in self?.indicator.notices.newestFirst ?? [] })"),
                      "openedHub() must hand the Hub the indicator's notices")
    }

    func testHomeListsTheNoticesWithTheirTime() throws {
        let home = try AppSource.body(of: "private struct HomeTab: View {", in: try AppSource.code("Hub.swift"))
        for line in ["Section(\"Recent notices\")", "let notices = model.notices()", "Text(NoticeLog.time(n.time))", "Text(n.text)"] {
            XCTAssertTrue(home.contains(line), "HomeTab lacks \(line)")
        }
    }
}
