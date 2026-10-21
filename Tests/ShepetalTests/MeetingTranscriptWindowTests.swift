import AppKit
import XCTest
import ShepetalCore
import SwiftUI
@testable import Shepetal

/// The window that opens after a recorded meeting. Its panel only records what it is asked to do and the
/// clipboard is a closure: these tests touch neither the screen, nor focus, nor the real pasteboard.
@MainActor
final class MeetingTranscriptWindowTests: XCTestCase {
    /// Never on screen: every call that would show it or give it the keyboard is only written down.
    final class RecordingPanel: TranscriptPanel {
        var calls: [String] = []
        override func orderFrontRegardless() { calls.append("orderFrontRegardless") }
        override func orderFront(_ sender: Any?) { calls.append("orderFront") }
        override func makeKeyAndOrderFront(_ sender: Any?) { calls.append("makeKeyAndOrderFront") }
        override func makeKey() { calls.append("makeKey") }
        override func makeMain() { calls.append("makeMain") }
    }

    private let store = InMemoryMeetingStore()
    private var copied: [String] = []
    private var opened: [String] = []
    private let panel = RecordingPanel()
    private var window: MeetingTranscriptWindow!

    override func setUp() async throws {
        window = MeetingTranscriptWindow(model: MeetingsModel(store: store, copy: { [unowned self] in copied.append($0) }),
                                         open: { [unowned self] in opened.append($0) }, panel: panel)
    }

    private func ended(_ id: String, _ app: String, minutesAgo: Double, said: [Segment]) throws -> Meeting {
        let start = Date().addingTimeInterval(-minutesAgo * 60)
        let m = Meeting(id: id, app: app, startedAt: start, endedAt: start.addingTimeInterval(60),
                        meAudioPath: "/m/\(id)/Me.wav", othersAudioPath: "/m/\(id)/Others.wav")
        try store.save(m)
        try store.append(said, to: id)
        return m
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Shepetal/\(file)").standardizedFileURL, encoding: .utf8)
            .components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // Rule 8: it comes to the front for the user to see, but keyboard focus stays in the app they are typing in.
    func testPanelNeverTakesFocusWhenItOpens() throws {
        XCTAssertTrue(TranscriptPanel().styleMask.contains(.nonactivatingPanel), "clicking it must not activate the app")
        XCTAssertFalse(panel.hidesOnDeactivate, "an accessory app is never active, so it would never show")
        window.show(try ended("a", "Zoom", minutesAgo: 5, said: [Segment(speaker: .me, start: 1, end: 2, text: "Hi")]))
        XCTAssertEqual(panel.calls, ["orderFrontRegardless"], "in front, but never made key")
        XCTAssertNil(try source("Meetings/MeetingTranscriptWindow.swift").range(of: "activate("),
                     "nothing on the transcript window's path may activate Shepetal")
    }

    func testTranscriptFirstThenTheSummaryAndCopiesOnlyOnAClick() throws {
        let m = try ended("a", "Zoom", minutesAgo: 5, said: [Segment(speaker: .others, start: 4, end: 9, text: "Ship it Friday?"),
                                                             Segment(speaker: .me, start: 10, end: 12, text: "Yes.")])
        window.show(m)
        XCTAssertEqual(panel.calls.count, 1)
        XCTAssertEqual(window.model.record?.segments.count, 2, "the transcript shows without waiting for the summary")
        XCTAssertNil(window.model.record?.summary)
        XCTAssertTrue(window.hosting.rootView.summarizing, "\"Summarizing…\" until it lands")
        XCTAssertFalse(window.model.canCopySummary)
        window.model.copySummary()  // greyed out until the summary is ready; does nothing if reached anyway
        XCTAssertEqual(copied, [], "opening the window never writes the clipboard")

        try store.setSummary(Summary(overview: "Ships Friday.", actionItems: [ActionItem(owner: "Me", task: "Ship")]), for: "a")
        window.model.refresh()  // what the view's poll does
        XCTAssertEqual(window.model.record?.summary?.overview, "Ships Friday.")
        XCTAssertEqual(panel.calls.count, 1, "the summary landing does not bring the window forward again")
        XCTAssertEqual(copied, [])

        window.model.copyTranscript()
        XCTAssertEqual(copied.last, MeetingFormat.transcript(try XCTUnwrap(store.get("a"))))
        XCTAssertEqual(window.model.message, "Transcript copied")
        window.model.copySummary()
        XCTAssertEqual(copied.count, 2)
        XCTAssertTrue(copied[1].contains("Ships Friday.") && !copied[1].contains("Ship it Friday?"), "summary only")
    }

    // "We decided to ship on Friday." gives decisions but no overview: Summarizing… ends, and the decision both
    // shows (the window uses the tab's sections) and is copied. Nothing at all to say: nothing to copy either.
    func testASummaryWithNothingInItIsNotOfferedForCopying() throws {
        window.show(try ended("a", "Zoom", minutesAgo: 5, said: [Segment(speaker: .me, start: 1, end: 2, text: "Okay.")]))
        try store.setSummary(Summary(overview: ""), for: "a")
        window.model.refresh()
        XCTAssertFalse(window.model.canCopySummary)
        window.model.copySummary()
        XCTAssertEqual(copied, [])

        try store.setSummary(Summary(overview: "", decisions: ["We decided to ship on Friday."]), for: "a")
        window.model.refresh()
        XCTAssertTrue(window.model.canCopySummary)
        window.model.copySummary()
        XCTAssertTrue(copied.last?.contains("## Decisions\n\n- We decided to ship on Friday.") == true)
    }

    // The final pass or the summary failed: the window opens with what was stored and stops promising a summary.
    func testNoSummaryComingEndsSummarizingWithoutBringingTheWindowBack() throws {
        let m = try ended("a", "Zoom", minutesAgo: 5, said: [Segment(speaker: .me, start: 1, end: 2, text: "Hi")])
        window.show(m, summarizing: true)
        window.show(m, summarizing: false)  // setSummary threw after the transcript was shown
        XCTAssertFalse(window.hosting.rootView.summarizing)
        XCTAssertEqual(panel.calls, ["orderFrontRegardless"], "a window the user closed in between stays closed")

        let b = try ended("b", "Zoom", minutesAgo: 1, said: [Segment(speaker: .me, start: 1, end: 2, text: "Half")])
        window.show(b, summarizing: false)  // the final pass threw before the transcript was ready
        XCTAssertEqual(panel.calls.count, 2, "what was stored still opens")
        XCTAssertEqual(window.model.record?.meeting.id, "b")
        XCTAssertFalse(window.hosting.rootView.summarizing)
    }

    // Three meetings ending: one panel, showing the latest, never a stack of copies.
    func testEveryMeetingTheFlowFinishesReusesOneWindow() throws {
        let flow = MeetingFlow(store: store, summarizer: MeetingTranscriberTests.StubSummarizer(), engine: { nil }, hint: { _ in })
        var panels: [RecordingPanel] = []
        _ = MeetingTranscriptWindow.follow(flow, open: { _ in }) { let p = RecordingPanel(); panels.append(p); return p }
        XCTAssertEqual(panels.count, 0, "no window before a meeting ends")
        for (i, id) in ["a", "b", "c"].enumerated() {
            flow.onTranscript(try ended(id, "Zoom", minutesAgo: Double(30 - i), said: [Segment(speaker: .me, start: 1, end: 2, text: id)]), true)
        }
        XCTAssertEqual(panels.count, 1)
        XCTAssertEqual(panels.first?.calls.count, 3, "each meeting brings it to the front")
        XCTAssertEqual((panels.first?.contentView as? NSHostingView<MeetingTranscriptView>)?.rootView.model.record?.meeting.id, "c")
    }

    // The 🤫 menu's Past meetings: the same one window, back in front even after the user closed it, never key.
    func testAPastMeetingFromTheMenuReusesTheWindowAndBringsItBack() throws {
        let flow = MeetingFlow(store: store, summarizer: MeetingTranscriberTests.StubSummarizer(), engine: { nil }, hint: { _ in })
        var panels: [RecordingPanel] = []
        let openPast = MeetingTranscriptWindow.follow(flow, open: { _ in }) { let p = RecordingPanel(); panels.append(p); return p }
        let a = try ended("a", "Zoom", minutesAgo: 30, said: [Segment(speaker: .me, start: 1, end: 2, text: "a")])
        let b = try ended("b", "Zoom", minutesAgo: 20, said: [Segment(speaker: .me, start: 1, end: 2, text: "b")])
        openPast(a)  // before any meeting ended in this run
        XCTAssertEqual(panels.count, 1)
        flow.onTranscript(b, true)
        openPast(b)  // the user closed it, then chose b in the menu
        XCTAssertEqual(panels.count, 1, "never a second window")
        XCTAssertEqual(panels[0].calls, ["orderFrontRegardless", "orderFrontRegardless", "orderFrontRegardless"],
                       "in front each time, never made key")
        let view = try XCTUnwrap((panels[0].contentView as? NSHostingView<MeetingTranscriptView>)?.rootView)
        XCTAssertEqual(view.model.record?.meeting.id, "b")
        XCTAssertFalse(view.summarizing, "a past meeting promises no summary, so nothing spins for ever")
    }

    func testTheNextMeetingClearsCopiedFromTheLastOne() throws {
        window.show(try ended("a", "Zoom", minutesAgo: 60, said: [Segment(speaker: .me, start: 1, end: 2, text: "First")]))
        window.model.copyTranscript()
        window.show(try ended("b", "Slack", minutesAgo: 5, said: [Segment(speaker: .me, start: 1, end: 2, text: "Second")]))
        XCTAssertEqual(panel.calls.count, 2)
        XCTAssertEqual(window.model.record?.meeting.id, "b")
        XCTAssertEqual(window.model.message, "", "\"copied\" was about the other meeting")
    }

    func testNoSpeechHasNothingToCopy() throws {
        window.show(try ended("a", "Zoom", minutesAgo: 5, said: []))
        XCTAssertEqual(window.model.record?.segments, [])
        window.model.copyTranscript()
        XCTAssertEqual(copied, [])
    }

    // ⌘C on a selection: with Caps Lock on, and on a Cyrillic layout, where the C key types "с".
    func testCommandCCopiesWithCapsLockAndOnAnyLayout() {
        func key(_ flags: NSEvent.ModifierFlags, _ chars: String, _ keyCode: UInt16 = 8) -> Bool {
            TranscriptPanel.isCopy(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!)
        }
        XCTAssertTrue(key(.command, "c"))
        XCTAssertTrue(key([.command, .capsLock], "c"))
        XCTAssertTrue(key([.command, .capsLock], "C"))
        XCTAssertTrue(key(.command, "с"), "Cyrillic с on the C key")
        XCTAssertFalse(key([.command, .shift], "c"))
        XCTAssertFalse(key([.command, .option], "c"))
        XCTAssertFalse(key([], "c"))
        XCTAssertFalse(key(.command, "v", 9))
        XCTAssertFalse(key(.command, "м", 9), "Cyrillic м is on the V key")
    }
}
