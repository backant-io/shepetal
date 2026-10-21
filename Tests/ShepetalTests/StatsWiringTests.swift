import XCTest

/// F60: the Home tab cannot be rendered in a test, so this pins by source that HomeTab shows "Your stats".
/// Without it, a lost wiring line leaves the stats unreachable and only the hand step would notice.
final class StatsWiringTests: XCTestCase {
    func testHomeTabShowsTheStatsSection() throws {
        let home = try AppSource.body(of: "private struct HomeTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(home.contains("StatsSection(history: model.pipeline.history)"), "HomeTab must show Your stats")
    }
}
