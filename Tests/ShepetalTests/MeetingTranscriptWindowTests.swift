import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// The window that opens after a recorded meeting. Its panel is never shown and the clipboard is a closure:
/// these tests touch neither the screen, nor focus, nor the real pasteboard.
@MainActor
final class MeetingTranscriptWindowTests: XCTestCase {
    private let store = InMemoryMeetingStore()
    private var copied: [String] = []
    private var presented = 0
    private var opened: [String] = []
    private var window: MeetingTranscriptWindow!

    override func setUp() async throws {
        window = MeetingTranscriptWindow(model: MeetingsModel(store: store, copy: { [unowned self] in copied.append($0) }),
                                         open: { [unowned self] in opened.append($0) },
                                         present: { [unowned self] _ in presented += 1 })
    }

    private func ended(_ id: String, _ app: String, minutesAgo: Double, said: [Segment]) throws -> Meeting {
        let start = Date().addingTimeInterval(-minutesAgo * 60)
        let m = Meeting(id: id, app: app, startedAt: start, endedAt: start.addingTimeInterval(60),
                        meAudioPath: "/m/\(id)/Me.wav", othersAudioPath: "/m/\(id)/Others.wav")
        try store.save(m)
        try store.append(said, to: id)
        return m
    }

    // Rule 8: it comes to the front for the user to see, but keyboard focus stays in the app they are typing in.
    func testPanelNeverTakesFocusWhenItOpens() {
        XCTAssertTrue(window.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.panel.isKeyWindow)
        XCTAssertFalse(window.panel.hidesOnDeactivate, "an accessory app is never active, so it would never show")
    }

    func testTranscriptFirstThenTheSummaryAndCopiesOnlyOnAClick() throws {
        let m = try ended("a", "Zoom", minutesAgo: 5, said: [Segment(speaker: .others, start: 4, end: 9, text: "Ship it Friday?"),
                                                             Segment(speaker: .me, start: 10, end: 12, text: "Yes.")])
        window.show(m)
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(window.model.record?.segments.count, 2, "the transcript shows without waiting for the summary")
        XCTAssertNil(window.model.record?.summary)
        window.model.copySummary()  // greyed out until the summary is ready; does nothing if reached anyway
        XCTAssertEqual(copied, [], "opening the window never writes the clipboard")

        try store.setSummary(Summary(overview: "Ships Friday.", actionItems: [ActionItem(owner: "Me", task: "Ship")]), for: "a")
        window.model.refresh()  // what the view's poll does
        XCTAssertEqual(window.model.record?.summary?.overview, "Ships Friday.")
        XCTAssertEqual(presented, 1, "the summary landing does not bring the window forward again")
        XCTAssertEqual(copied, [])

        window.model.copyTranscript()
        XCTAssertEqual(copied.last, MeetingFormat.transcript(try XCTUnwrap(store.get("a"))))
        XCTAssertEqual(window.model.message, "Transcript copied")
        window.model.copySummary()
        XCTAssertEqual(copied.count, 2)
        XCTAssertTrue(copied[1].contains("Ships Friday.") && !copied[1].contains("Ship it Friday?"), "summary only")
    }

    // Two meetings ending: one window, showing the latest, never a second copy.
    func testTheNextMeetingReusesTheWindow() throws {
        let panel = window.panel
        window.show(try ended("a", "Zoom", minutesAgo: 60, said: [Segment(speaker: .me, start: 1, end: 2, text: "First")]))
        window.model.copyTranscript()
        window.show(try ended("b", "Slack", minutesAgo: 5, said: [Segment(speaker: .me, start: 1, end: 2, text: "Second")]))
        XCTAssertTrue(window.panel === panel)
        XCTAssertEqual(presented, 2)
        XCTAssertEqual(window.model.record?.meeting.id, "b")
        XCTAssertEqual(window.model.message, "", "\"copied\" was about the other meeting")
    }

    func testNoSpeechHasNothingToCopy() throws {
        window.show(try ended("a", "Zoom", minutesAgo: 5, said: []))
        XCTAssertEqual(window.model.record?.segments, [])
        window.model.copyTranscript()
        XCTAssertEqual(copied, [])
    }
}
