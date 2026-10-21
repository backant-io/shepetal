import XCTest
import ShepetalCore
import ShepetalSummary
@testable import Shepetal

/// F73 and F123 in the Meetings tab: the Ask pane's model and the Latin-script toggle. In-memory store and a
/// recording copy closure: no clipboard, no window, no save panel.
@MainActor
final class MeetingAskViewTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_792_508_400)  // 2026-10-20 15:00 UTC

    private func record(_ id: String, at start: Date, _ segments: [Segment]) throws -> MeetingRecord {
        MeetingRecord(meeting: Meeting(id: id, app: "zoom.us", startedAt: start, endedAt: start.addingTimeInterval(600),
                                       meAudioPath: "", othersAudioPath: ""),
                      segments: segments, summary: try MeetingSummarizer().summarize(segments))
    }

    private var call: [Segment] {
        [Segment(speaker: .others, start: 2, end: 6, text: "Thanks for joining. Let's go through the launch."),
         Segment(speaker: .me, start: 7, end: 12, text: "Sure. The budget looks tight to me."),
         Segment(speaker: .others, start: 13, end: 20, text: "The budget is fine if we drop the paid ads."),
         Segment(speaker: .me, start: 21, end: 25, text: "I will send the slides by Friday."),
         Segment(speaker: .others, start: 26, end: 31, text: "I will review the budget tomorrow.")]
    }

    // M-MTG-10: "who will send the slides" gives Me's action item, "what did they say about the budget" the Others
    // line with its time, and a click opens the transcript at that line.
    func testAskAnswersWithQuotesAndAClickOpensTheTranscriptThere() throws {
        let store = InMemoryMeetingStore([try record("call", at: t0, call),
                                          try record("other", at: t0.addingTimeInterval(-86_400),
                                                     [Segment(speaker: .others, start: 5, end: 9, text: "The hiring plan is on hold.")])])
        var copied: [String] = []
        let model = MeetingsModel(store: store, copy: { copied.append($0) })
        model.refresh()
        XCTAssertEqual(model.selectedID, "call")

        model.ask.ask("Who will send the slides?", in: "call")
        let slides = try XCTUnwrap(model.ask.turns(in: "call").last?.answer.quotes.first)
        XCTAssertEqual(MeetingAskModel.line(slides), "Me: send the slides (Friday)")
        XCTAssertEqual(MeetingAskModel.caption(slides, headline: nil), "Action item · 0:21")

        model.ask.ask("what did they say about the budget", in: "call")
        let budget = try XCTUnwrap(model.ask.turns(in: "call").last?.answer.quotes.first)
        XCTAssertEqual(MeetingAskModel.line(budget), "“The budget is fine if we drop the paid ads.”")
        XCTAssertEqual(MeetingAskModel.caption(budget, headline: nil), "Others · 0:13")
        XCTAssertEqual(model.ask.turns(in: "call").map(\.question), ["Who will send the slides?", "what did they say about the budget"],
                       "the turns stay for the session")

        // Asked about all meetings, the hiring line comes from the other meeting and names it; the click opens it.
        model.ask.ask("hiring plan", in: nil)
        let turn = try XCTUnwrap(model.ask.turns(in: nil).last)
        let hiring = try XCTUnwrap(turn.answer.quotes.first)
        XCTAssertEqual(hiring.meetingID, "other")
        XCTAssertEqual(MeetingAskModel.caption(hiring, headline: turn.headlines[hiring.meetingID]),
                       "Others · 0:05 · " + MeetingFormat.headline(try XCTUnwrap(store.get("other")).meeting))
        XCTAssertEqual(model.ask.turns(in: "call").count, 2, "each scope keeps its own questions")
        model.openTranscript(hiring.meetingID, segment: try XCTUnwrap(hiring.segment))
        XCTAssertEqual(model.selectedID, "other")
        XCTAssertEqual(model.jump?.meetingID, "other")
        XCTAssertEqual(model.jump?.segment, 0)

        // Back on the call: the budget line opens its transcript at segment 2, and a second click is a new jump.
        model.openTranscript("call", segment: try XCTUnwrap(budget.segment))
        XCTAssertEqual(model.record?.meeting.id, "call")
        XCTAssertEqual(model.jump?.segment, 2)
        let first = model.jump
        model.openTranscript("call", segment: 2)
        XCTAssertNotEqual(model.jump, first, "clicking the same line again scrolls there again")
        XCTAssertEqual(copied, [], "asking never writes the clipboard")
    }

    func testNothingFoundIsSaidPlainly() throws {
        let store = InMemoryMeetingStore([try record("call", at: t0, call)])
        let model = MeetingsModel(store: store, copy: { _ in })
        model.ask.ask("What did they say about the kubernetes migration?", in: "call")
        XCTAssertEqual(model.ask.turns(in: "call").last?.answer.quotes, [])
        XCTAssertEqual(MeetingAskModel.nothingFound(allMeetings: false), "Nothing in this meeting answers that.")
        XCTAssertEqual(MeetingAskModel.nothingFound(allMeetings: true), "Nothing in your meetings answers that.")
        model.ask.ask("  ", in: "call")
        XCTAssertEqual(model.ask.turns(in: "call").count, 1, "an empty question is not asked")
    }

    // Notes typed during the call count: their action items are part of the summary the pane shows.
    func testTypedNotesAreAskedAboutToo() throws {
        let store = InMemoryMeetingStore([try record("call", at: t0, call)])
        try store.setNotes("TODO: book the retro room", for: "call")
        let model = MeetingsModel(store: store, copy: { _ in })
        model.ask.ask("who will book the retro room", in: "call")
        let q = try XCTUnwrap(model.ask.turns(in: "call").last?.answer.quotes.first)
        XCTAssertEqual(MeetingAskModel.line(q), "Me: book the retro room")
        XCTAssertNil(q.segment, "said in no line, so nothing to open")
        XCTAssertEqual(MeetingAskModel.caption(q, headline: nil), "Action item")
    }

    // F123: the toggle shows only for meetings with letters outside the Latin script.
    func testLatinToggleShowsOnlyForNonLatinMeetings() throws {
        let store = InMemoryMeetingStore([
            MeetingRecord(meeting: Meeting(id: "en", app: "Zoom", startedAt: t0, endedAt: t0.addingTimeInterval(60), meAudioPath: "", othersAudioPath: ""),
                          segments: [Segment(speaker: .me, start: 1, end: 2, text: "Café at noon, Łódź office.")]),
            MeetingRecord(meeting: Meeting(id: "ru", app: "Zoom", startedAt: t0.addingTimeInterval(-60), endedAt: t0, meAudioPath: "", othersAudioPath: ""),
                          segments: [Segment(speaker: .others, start: 3, end: 5, text: "Бюджет утвердили.")]),
            MeetingRecord(meeting: Meeting(id: "notes", app: "Zoom", startedAt: t0.addingTimeInterval(-120), endedAt: t0, meAudioPath: "", othersAudioPath: ""),
                          summary: Summary(overview: "Καλημέρα."))
        ])
        let model = MeetingsModel(store: store, copy: { _ in })
        model.refresh()
        model.select("en")
        XCTAssertFalse(model.canShowLatin)
        model.select("ru")
        XCTAssertTrue(model.canShowLatin)
        model.select("notes")
        XCTAssertTrue(model.canShowLatin, "a summary in Greek counts")
    }

    // F123: Copy transcript, Copy summary and Export follow the toggle; the store keeps the original.
    func testCopyAndExportFollowTheToggle() throws {
        let segs = [Segment(speaker: .others, start: 4, end: 9, text: "Бюджет утвердили?"),
                    Segment(speaker: .me, start: 247, end: 251, text: "Да, я пришлю слайды.")]
        let r = MeetingRecord(meeting: Meeting(id: "ru", app: "Zoom", startedAt: t0, endedAt: t0.addingTimeInterval(600), meAudioPath: "", othersAudioPath: ""),
                              segments: segs, summary: Summary(overview: "Бюджет утвердили.", decisions: ["Слайды в пятницу"]))
        let store = InMemoryMeetingStore([r])
        var copied: [String] = []
        let model = MeetingsModel(store: store, copy: { copied.append($0) })
        model.refresh()

        model.copyTranscript()
        XCTAssertTrue(copied.last?.contains("Others (0:04): Бюджет утвердили?") ?? false, copied.last ?? "")
        XCTAssertTrue(model.exportMarkdown?.contains("Бюджет утвердили.") ?? false)

        model.latin = true
        model.copyTranscript()
        XCTAssertTrue(copied.last?.contains("Others (0:04): Bûdžet utverdili?") ?? false, copied.last ?? "")
        XCTAssertTrue(copied.last?.contains("Me (4:07): Da, â prišlû slajdy.") ?? false, copied.last ?? "")
        model.copySummary()
        XCTAssertTrue(copied.last?.contains("Bûdžet utverdili.") ?? false)
        XCTAssertTrue(copied.last?.contains("- Slajdy v pâtnicu") ?? false)
        let md = try XCTUnwrap(model.exportMarkdown)
        XCTAssertFalse(Romanize.needsLatin(md), md)
        XCTAssertTrue(md.contains("- **Me** (4:07): Da, â prišlû slajdy."), md)
        XCTAssertEqual(model.shown(r).segments.map(\.text), ["Bûdžet utverdili?", "Da, â prišlû slajdy."])
        XCTAssertEqual(try store.get("ru"), r, "never written back")
        XCTAssertEqual(model.record, r, "the record the Notes editor edits stays the original")

        model.latin = false
        model.copyTranscript()
        XCTAssertTrue(copied.last?.contains("Бюджет утвердили?") ?? false)
        XCTAssertEqual(model.exportMarkdown, MeetingFormat.markdown(r))
    }

    // The transcript window's copy follows the same toggle (it shares the model).
    func testTheTranscriptWindowFollowsTheToggle() throws {
        let store = InMemoryMeetingStore()
        var copied: [String] = []
        let window = MeetingTranscriptWindow(model: MeetingsModel(store: store, copy: { copied.append($0) }), open: { _ in },
                                             panel: MeetingTranscriptWindowTests.RecordingPanel())
        let m = Meeting(id: "gr", app: "Zoom", startedAt: t0, endedAt: t0.addingTimeInterval(60), meAudioPath: "", othersAudioPath: "")
        try store.save(m)
        try store.append([Segment(speaker: .others, start: 1, end: 2, text: "Καλημέρα σας")], to: "gr")
        window.show(m)
        XCTAssertTrue(window.model.canShowLatin)
        window.model.latin = true
        window.model.copyTranscript()
        XCTAssertTrue(copied.last?.hasSuffix("Others (0:01): Kalēméra sas\n") ?? false, copied.last ?? "")
    }
}
