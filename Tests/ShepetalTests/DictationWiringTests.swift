import XCTest

/// The app delegate cannot run in a test (it puts 🤫 on screen and opens the mic), so this pins by source the
/// lines that hand dictation to F09, F99, F102 and F114. A lost line would leave the feature dead while every
/// unit test of it stays green.
final class DictationWiringTests: XCTestCase {
    private func app() throws -> String { try AppSource.code("App.swift") }

    /// The body of `func name(` in App.swift, up to the next function at the same indent.
    private func function(_ name: String) throws -> String {
        let app = try app()
        let from = try XCTUnwrap(app.range(of: "func \(name)("), name)
        let rest = app[from.upperBound...]
        return String(rest[..<(rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex)])
    }

    /// F102: in a turned-off app fn records nothing, and the check comes before "Still transcribing" and the
    /// sign-in gate. The menu offers the switch with the input items.
    func testATurnedOffAppStopsFnBeforeAnythingElse() throws {
        let key = try function("key")
        let gate = try XCTUnwrap(key.range(of: "if let off = dictationOff.hint(for: input, idle: idle) { return indicator.show(off, seconds: Hint.seconds) }"))
        let firstCase = try XCTUnwrap(key.range(of: "switch input {"))
        XCTAssertLessThan(gate.lowerBound, firstCase.lowerBound)
        XCTAssertTrue(try function("menuNeedsUpdate").contains("dictationOff.menuItems()"))
    }

    /// F09: every way a dictation ends gives the sound and the paused media back, the throwing one included.
    func testEveryEndOfADictationRestoresTheMedia() throws {
        let show = try function("show")
        for c in ["case .tooShort:\n            media.end()", "case .cancel:\n            media.end()", "case .stop: media.end()"] {
            XCTAssertTrue(show.contains(c), c)
        }
        XCTAssertTrue(show.contains("media.begin(mute: dictation?.gesture.holdThreshold ?? 0.5, pause: dictation?.gesture.chordWindow ?? 1)"),
                      "pause waits for the chord window, so fn+arrow never pauses")
        XCTAssertTrue(show.contains("media.begin(mute: 0, pause: 0)"), "hands-free acts at once")
        XCTAssertTrue(try function("run").contains("} catch {\n            media.end()"), "a throw skips show(.cancel)")
        XCTAssertTrue(try function("applicationWillTerminate").contains("media.end()"))
    }

    /// F114: the creator label is set as recording starts, after set(.recording), which would clear it.
    func testTheCreatorLabelIsSetAsRecordingStarts() throws {
        let show = try function("show")
        let recording = try XCTUnwrap(show.range(of: "indicator.set(.recording)"))
        let label = try XCTUnwrap(show.range(of: "indicator.status = Indicator.creatorStatus()"))
        XCTAssertLessThan(recording.lowerBound, label.lowerBound)
        let settings = try AppSource.body(of: "private struct SettingsTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(settings.contains("@AppStorage(Indicator.creatorModeKey) private var creatorMode = false"))
        XCTAssertTrue(settings.contains("isOn: $creatorMode)"))
    }

    /// F99: the watchdog starts before anything else at launch, and Quit marks a clean quit before any teardown.
    func testTheWatchdogStartsFirstAndQuitStaysQuit() throws {
        let launch = try function("applicationDidFinishLaunching")
        XCTAssertTrue(launch.hasPrefix("_ notification: Notification) {\n        let crashHint = Watchdog.start()"), "first line")
        XCTAssertTrue(launch.contains("if let crashHint { indicator.show(crashHint, seconds: 8) }"))
        XCTAssertTrue(try function("applicationWillTerminate").hasPrefix("_ notification: Notification) {\n        Watchdog.quitting()"))
        let main = try AppSource.code("main.swift")
        let watchdog = try XCTUnwrap(main.range(of: "if let i = args.firstIndex(of: Watchdog.flag) { Watchdog.main(Array(args[(i + 1)...])) }"))
        let app = try XCTUnwrap(main.range(of: "MainActor.assumeIsolated {"))
        XCTAssertLessThan(watchdog.lowerBound, app.lowerBound, "--watchdog never starts a second app")
    }
}
