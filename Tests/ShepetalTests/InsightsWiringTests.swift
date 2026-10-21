import XCTest

/// F61, F62: Home, Settings and the end of a dictation cannot run in a test, so this pins the wiring by source.
/// Without it, a lost line leaves the streak, Insights or the milestone note unreachable, and only a hand step
/// would notice.
final class InsightsWiringTests: XCTestCase {
    func testHomeTabShowsInsights() throws {
        let home = try AppSource.body(of: "private struct HomeTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(home.contains("InsightsSection(history: model.pipeline.history)"), "HomeTab must show Insights")
    }

    // On unless the user turns it off: the same default Streak.notice reads.
    func testSettingsHasMilestoneNotices() throws {
        let settings = try AppSource.body(of: "private struct SettingsTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(settings.contains("@AppStorage(Streak.noticesKey) private var milestoneNotices = true"))
        XCTAssertTrue(settings.contains("Toggle(\"Milestone notices\", isOn: $milestoneNotices)"))
    }

    // After a dictation whose text landed, the note goes next to 🤫; an error message is never covered by it.
    func testADeliveredDictationTellsItsMilestone() throws {
        let app = try AppSource.code("App.swift")
        let rest = try XCTUnwrap(app.components(separatedBy: "private func transcribe(").dropFirst().first)
        let transcribe = try XCTUnwrap(rest.components(separatedBy: "\n    }\n").first, "transcribe(_:)'s body only")
        let note = "if let note = await Task.detached(operation: { Streak.notice(after: id, in: history) }).value { indicator.show(note, seconds: 6) }"
        for line in ["if run.error == nil, !Task.isCancelled {", "let history = pipeline.history, id = run.entry.id", note] {
            XCTAssertTrue(transcribe.contains(line), "transcribe(_:) lacks \(line)")
        }
        // A crossing is told only once, so the quiet-mic hint must come first or it would cover the note.
        let quiet = try XCTUnwrap(transcribe.range(of: "indicator.show(MicHealth.quietHint"), "the quiet-mic hint moved")
        XCTAssertLessThan(quiet.lowerBound, try XCTUnwrap(transcribe.range(of: note)).lowerBound)
    }
}
