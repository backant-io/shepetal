@testable import ShepetalCore
import XCTest
@testable import Shepetal

/// F60: what Home's "Your stats" prints. A few short dictations must not read as "0 min".
final class StatsFormatTests: XCTestCase {
    func testDurationUnits() {
        XCTAssertEqual(StatsFormat.duration(0), "0 s")
        XCTAssertEqual(StatsFormat.duration(0.75), "45 s")
        XCTAssertEqual(StatsFormat.duration(12.2), "12 min")
        XCTAssertEqual(StatsFormat.duration(59.6), "1 h 0 min")
        XCTAssertEqual(StatsFormat.duration(125), "2 h 5 min")
    }

    func testRowsPutTheWeekNextToAllTime() {
        var week = DictationStats()
        week.dictations = 2; week.words = 120; week.speakingMs = 60_000
        week.apps = [.init(app: "Notes", words: 80), .init(app: "Slack", words: 40)]
        var all = week
        all.dictations = 3; all.words = 130; all.speakingMs = 120_000
        all.apps += [.init(app: "Mail", words: 6), .init(app: "unknown app", words: 4)]
        XCTAssertEqual(StatsFormat.rows(week: week, all: all), [
            .init(title: "Words", week: "120", all: "130"),
            .init(title: "Dictations", week: "2", all: "3"),
            .init(title: "Words per minute", week: "120", all: "65"),
            .init(title: "Speaking time", week: "1 min", all: "2 min"),
            .init(title: "Time saved", week: "2 min", all: "1 min"),
            .init(title: "Top apps", week: "Notes: 80\nSlack: 40", all: "Notes: 80\nSlack: 40\nMail: 6"),
        ])
        XCTAssertEqual(StatsFormat.rows(week: DictationStats(), all: DictationStats()).last?.all, "–")
    }
}
