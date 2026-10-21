import XCTest
@testable import ShepetalCore

/// F13: the words next to 🤫 while recording are a preview. The speech engine runs one pass at a time, so the final
/// pass on release waits behind a partial still running. These pin what keeps that wait short and the preview
/// honest: at most one pass a second, never two at once, only the end of the recording, nothing on silence, and
/// nothing shown once the dictation ended.
final class LiveTextTests: XCTestCase {
    let rate = AudioStore.sampleRate
    /// 12 s at speech level. The sine never repeats on whole samples, so the end of it differs from its start.
    static let speech = (0..<12 * AudioStore.sampleRate).map { Float(sin(Double($0) * 0.2)) * 0.045 }
    var speech: [Float] { Self.speech }

    func testAtMostOnePassASecond() throws {
        var live = LiveText()
        live.start(at: 100)
        XCTAssertNil(live.pass(speech, at: 100.75), "no pass in the first second")
        let first = try XCTUnwrap(live.pass(speech, at: 101))
        XCTAssertEqual(live.finished(first.id, text: "hello"), "hello")
        XCTAssertNil(live.pass(speech, at: 101.9), "under a second since the last pass began")
        XCTAssertNotNil(live.pass(speech, at: 102))
    }

    func testNeverTwoPassesAtOnce() throws {
        var live = LiveText()
        live.start(at: 0)
        let first = try XCTUnwrap(live.pass(speech, at: 1))
        XCTAssertNil(live.pass(speech, at: 5), "the first pass is still running")
        XCTAssertNil(live.finished(first.id, text: nil), "a failed pass shows nothing")
        XCTAssertNotNil(live.pass(speech, at: 5), "and frees the engine for the next one")
    }

    func testOnlyTheLastTenSecondsGoToTheEngine() throws {
        var live = LiveText()
        live.start(at: 0)
        let pass = try XCTUnwrap(live.pass(speech, at: 1))
        XCTAssertEqual(pass.samples.count, 10 * rate)
        XCTAssertEqual(pass.samples, Array(speech.suffix(10 * rate)), "the end of the recording, not its start")
        _ = live.finished(pass.id, text: "x")
        let short = Array(speech.prefix(3 * rate))
        XCTAssertEqual(live.pass(short, at: 2)?.samples, short, "a shorter recording goes whole")
    }

    func testSilenceRunsNoPassAndSpeechRunsAtTheNextTick() {
        var live = LiveText()
        live.start(at: 0)
        let silence = [Float](repeating: 0, count: 2 * rate)
        XCTAssertNil(live.pass(silence, at: 1), "audio below the speech floor never reaches the engine")
        XCTAssertNotNil(live.pass(silence + speech.prefix(rate), at: 1.25), "a silent tick does not cost a second")
    }

    func testAPartialThatReturnsAfterTheDictationIsDropped() throws {
        var live = LiveText()
        XCTAssertNil(live.pass(speech, at: 10), "nothing runs before a dictation starts")
        live.start(at: 0)
        let old = try XCTUnwrap(live.pass(speech, at: 1))
        live.stop()  // release, Esc or too short while the pass runs
        XCTAssertNil(live.pass(speech, at: 10), "no pass after the stop")
        XCTAssertNil(live.finished(old.id, text: "late words"), "a partial after the stop is dropped")

        // The next dictation starts while a pass of the last one still runs.
        live.start(at: 20)
        let stale = try XCTUnwrap(live.pass(speech, at: 21))
        live.stop()
        live.start(at: 30)
        let current = try XCTUnwrap(live.pass(speech, at: 31), "a pass of the last dictation does not block this one")
        XCTAssertNil(live.finished(stale.id, text: "last dictation"), "never shown in the next dictation")
        XCTAssertNil(live.pass(speech, at: 40), "and it does not free the engine: this dictation's pass still runs")
        XCTAssertEqual(live.finished(current.id, text: "this one"), "this one")
    }

    func testTailIsTheLastWordsCutAtAWordBoundary() {
        let text = "Please send the quarterly report to the design team before Friday afternoon"
        let tail = LiveText.tail(text)
        XCTAssertEqual(tail, "…the design team before Friday afternoon")
        XCTAssertLessThanOrEqual(tail.count, LiveText.tailLength + 1)
        let words = tail.dropFirst()
        XCTAssertTrue(text.hasSuffix(words) && text.dropLast(words.count).hasSuffix(" "), "whole words only")
        XCTAssertEqual(LiveText.tail("send the report"), "send the report", "short text is kept whole, without …")
        XCTAssertEqual(LiveText.tail(" send\nthe   report "), "send the report", "one space between words")
        let long = String(repeating: "a", count: 50) + "z"
        XCTAssertEqual(LiveText.tail(long), "…" + long.suffix(LiveText.tailLength), "one word longer than the tail")
        XCTAssertEqual(LiveText.tail(""), "")
    }

    func testNoWordsKeepTheLabel() throws {
        var live = LiveText()
        live.start(at: 0)
        let pass = try XCTUnwrap(live.pass(speech, at: 1))
        XCTAssertNil(live.finished(pass.id, text: "  "), "a pass that heard no words leaves the last words up")
    }

    func testSettingUnsetMeansTheDefault() throws {
        let name = "io.backant.shepetal.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(LiveText.isOn(defaults), LiveText.defaultOn)
        defaults.set(!LiveText.defaultOn, forKey: LiveText.key)
        XCTAssertEqual(LiveText.isOn(defaults), !LiveText.defaultOn, "the Settings toggle wins over the default")
    }
}
