import XCTest

/// F13: the app delegate cannot run in a test (it puts 🤫 on screen and opens the mic), so this pins by source the
/// lines that start live text with the recording, stop it at every end, show it in the indicator's label and offer
/// the setting. A lost line would leave live text dead, or running after the release, while its unit tests stay green.
final class LiveTextWiringTests: XCTestCase {
    private func show() throws -> String {
        let app = try AppSource.code("App.swift")
        let from = try XCTUnwrap(app.range(of: "private func show(_ action: GestureAction) {"))
        let rest = app[from.upperBound...]
        return String(rest[..<(rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex)])
    }

    func testLiveTextRunsWithTheRecordingAndStopsAtEveryEnd() throws {
        let app = try AppSource.code("App.swift")
        XCTAssertTrue(app.contains("LiveCaption(recorded: { [mic] in mic.recorder.snapshot(last: LiveText.windowSamples) },"),
                      "partials read the end of the recording without stopping it")
        XCTAssertTrue(app.contains("engine: { [weak self] in self?.engine }) { [weak self] in self?.indicator.status = Indicator.liveStatus($0) }"),
                      "the words go to the indicator's label, after the creator label, nowhere else")
        let show = try show()
        let label = try XCTUnwrap(show.range(of: "indicator.status = Indicator.creatorStatus()"))
        let start = try XCTUnwrap(show.range(of: "liveText.start()"))
        XCTAssertLessThan(label.lowerBound, start.lowerBound, "after set(.recording), which clears the label")
        for end in ["case .tooShort:\n            media.end()\n            liveText.stop()",
                    "case .cancel:\n            media.end()\n            liveText.stop()",
                    "case .stop: media.end(); liveText.stop()"] {
            XCTAssertTrue(show.contains(end), end)
        }
    }

    func testSettingsOffersTheToggle() throws {
        let settings = try AppSource.body(of: "private struct SettingsTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(settings.contains("@AppStorage(LiveText.key) private var liveText = LiveText.defaultOn"))
        XCTAssertTrue(settings.contains("Toggle(\"Show words while you speak\", isOn: $liveText)"))
    }
}
