import XCTest
import ShepetalCore
@testable import Shepetal

/// The Meetings tab's text: what lands in the exported file and on the clipboard has to read right in any
/// editor, and the tab has to follow a live meeting. Runs on an in-memory store; never touches the clipboard.
@MainActor
final class MeetingsViewTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_792_508_400)  // 2026-10-20 15:00 UTC

    private func meeting(_ id: String, _ app: String, at start: Date, minutes: Double? = 42) -> Meeting {
        Meeting(id: id, app: app, startedAt: start, endedAt: minutes.map { start.addingTimeInterval($0 * 60) },
                meAudioPath: "/m/\(id)-me.wav", othersAudioPath: "/m/\(id)-others.wav")
    }

    private var record: MeetingRecord {
        MeetingRecord(
            meeting: meeting("a", "Google Meet (Chrome)", at: t0, minutes: 65),
            segments: [Segment(speaker: .others, start: 4, end: 9, text: "Shall we ship the beta on Friday?"),
                       Segment(speaker: .me, start: 247, end: 251, text: "Yes, I will send the notes.")],
            summary: Summary(overview: "The beta ships on Friday.",
                             keyPoints: ["Two bugs are open"],
                             decisions: ["Ship the beta on Friday"],
                             actionItems: [ActionItem(owner: "Pavel", task: "Send the notes", due: "tomorrow"),
                                           ActionItem(owner: "", task: "Fix the two bugs")]))
    }

    func testDurationReadsInMinutesAndHours() {
        XCTAssertEqual(MeetingFormat.duration(meeting("a", "Zoom", at: t0, minutes: 0.5)), "< 1 min")
        XCTAssertEqual(MeetingFormat.duration(meeting("a", "Zoom", at: t0, minutes: 42)), "42 min")
        XCTAssertEqual(MeetingFormat.duration(meeting("a", "Zoom", at: t0, minutes: 60)), "1 h")
        XCTAssertEqual(MeetingFormat.duration(meeting("a", "Zoom", at: t0, minutes: 65.9)), "1 h 5 min")
        // A running meeting has no end yet, so it counts up to now.
        let live = meeting("a", "Zoom", at: t0, minutes: nil)
        XCTAssertEqual(MeetingFormat.duration(live, now: t0.addingTimeInterval(7 * 60)), "7 min")
        XCTAssertEqual(MeetingFormat.duration(live, now: t0.addingTimeInterval(-60)), "< 1 min")
    }

    func testClockIsTheOffsetIntoTheMeeting() {
        XCTAssertEqual(MeetingFormat.clock(0), "0:00")
        XCTAssertEqual(MeetingFormat.clock(7.9), "0:07")
        XCTAssertEqual(MeetingFormat.clock(247), "4:07")
        XCTAssertEqual(MeetingFormat.clock(3723), "1:02:03")
    }

    func testActionItemWithoutOwnerSaysUnassigned() {
        XCTAssertEqual(MeetingFormat.owner(ActionItem(owner: "Pavel", task: "x")), "Pavel")
        XCTAssertEqual(MeetingFormat.owner(ActionItem(owner: "", task: "x")), "Unassigned")
        XCTAssertEqual(MeetingFormat.owner(ActionItem(owner: "  ", task: "x")), "Unassigned")
        XCTAssertEqual(MeetingFormat.actionLine(ActionItem(owner: "Me", task: "Book the room", due: "Friday")),
                       "- [ ] **Me**: Book the room (due Friday)")
        XCTAssertEqual(MeetingFormat.actionLine(ActionItem(owner: "", task: "Book the room")),
                       "- [ ] **Unassigned**: Book the room")
    }

    func testMarkdownExport() {
        XCTAssertEqual(MeetingFormat.markdown(record, timeZone: utc), """
        # Google Meet (Chrome) · 20.10.26 15:00 · 1 h 5 min

        ## Overview

        The beta ships on Friday.

        ## Key points

        - Two bugs are open

        ## Decisions

        - Ship the beta on Friday

        ## Action items

        - [ ] **Pavel**: Send the notes (due tomorrow)
        - [ ] **Unassigned**: Fix the two bugs

        ## Transcript

        - **Others** (0:04): Shall we ship the beta on Friday?
        - **Me** (4:07): Yes, I will send the notes.

        """)
    }

    func testCopiedSummaryHasNoTranscriptAndEmptySectionsAreLeftOut() {
        var r = record
        r.summary = Summary(overview: "Short call.")
        XCTAssertEqual(MeetingFormat.markdown(r, transcript: false, timeZone: utc), """
        # Google Meet (Chrome) · 20.10.26 15:00 · 1 h 5 min

        ## Overview

        Short call.

        """)
        // Before the summary is written the export is the transcript alone.
        r.summary = nil
        let md = MeetingFormat.markdown(r, timeZone: utc)
        XCTAssertFalse(md.contains("## Overview"))
        XCTAssertTrue(md.contains("## Transcript\n\n- **Others** (0:04)"))
    }

    // F71: the user's own notes lead the export and the copied summary, as typed but without list markers.
    func testMarkdownPutsYourNotesFirst() {
        var r = record
        r.notes = "- Kate owns the beta\n\n* check the two bugs\n"
        XCTAssertEqual(MeetingFormat.markdown(r, transcript: false, timeZone: utc), """
        # Google Meet (Chrome) · 20.10.26 15:00 · 1 h 5 min

        ## Your notes

        - Kate owns the beta
        - check the two bugs

        ## Overview

        The beta ships on Friday.

        ## Key points

        - Two bugs are open

        ## Decisions

        - Ship the beta on Friday

        ## Action items

        - [ ] **Pavel**: Send the notes (due tomorrow)
        - [ ] **Unassigned**: Fix the two bugs

        """)
        // No summary yet (or none at all): the notes are still exported.
        r.summary = nil
        XCTAssertTrue(MeetingFormat.markdown(r, timeZone: utc).hasPrefix("# Google Meet (Chrome) · 20.10.26 15:00 · 1 h 5 min\n\n## Your notes\n\n- Kate owns the beta\n"))
    }

    func testHeadlineReadsDayMonthYearAndNamesNoAppForAMeetingRecordedByHand() {
        XCTAssertEqual(MeetingFormat.headline(record.meeting, timeZone: utc), "Google Meet (Chrome) · 20.10.26 15:00 · 1 h 5 min")
        XCTAssertEqual(MeetingFormat.headline(meeting("m", MeetingRecorder.manualApp, at: t0), timeZone: utc),
                       "20.10.26 15:00 · 42 min")
        // Copy summary and the export head the same way as the window: no "Manual", DD.MM.YY.
        XCTAssertEqual(MeetingFormat.markdown(MeetingRecord(meeting: meeting("m", MeetingRecorder.manualApp, at: t0)), timeZone: utc),
                       "# 20.10.26 15:00 · 42 min\n")
    }

    // Pasted into a chat or a doc, it must read without Markdown and keep who said what when; no summary.
    func testCopiedTranscriptIsPlainTextWithSpeakersAndTimes() {
        XCTAssertEqual(MeetingFormat.transcript(record, timeZone: utc), """
        Google Meet (Chrome) · 20.10.26 15:00 · 1 h 5 min

        Others (0:04): Shall we ship the beta on Friday?
        Me (4:07): Yes, I will send the notes.

        """)
    }

    func testFilenameHasNoPathSeparators() {
        XCTAssertEqual(MeetingFormat.filename(meeting("a", "Teams: Web/Edge", at: t0), timeZone: utc),
                       "Teams- Web-Edge 2026-10-20 1500.md")
    }

    func testSearchMatchesAppTranscriptAndSummaryNewestFirst() throws {
        let store = InMemoryMeetingStore()
        try store.save(meeting("old", "Zoom", at: t0))
        try store.save(meeting("new", "FaceTime", at: t0.addingTimeInterval(3600)))
        try store.append([Segment(speaker: .others, start: 1, end: 2, text: "The BUDGET is fine")], to: "old")
        try store.setSummary(Summary(overview: "", actionItems: [ActionItem(owner: "Ana", task: "Check budget")]), for: "new")

        XCTAssertEqual(try store.list(limit: 10).map(\.id), ["new", "old"])
        XCTAssertEqual(try store.search("budget", limit: 10).map(\.id), ["new", "old"])
        XCTAssertEqual(try store.search("zoom", limit: 10).map(\.id), ["old"])
        XCTAssertEqual(try store.search("ana", limit: 10).map(\.id), ["new"])
        XCTAssertEqual(try store.search("nothing", limit: 10), [])
        XCTAssertThrowsError(try store.append([], to: "missing"))
    }

    func testTabFollowsALiveMeetingAndCopiesOnlyOnTheButton() throws {
        let store = InMemoryMeetingStore()
        var copied: [String] = []
        let model = MeetingsModel(store: store, copy: { copied.append($0) })
        model.refresh()
        XCTAssertNil(model.record)

        // A meeting starts: the tab opens it, and new segments show up on the next refresh.
        try store.save(meeting("live", "Zoom", at: t0, minutes: nil))
        model.refresh()
        XCTAssertEqual(model.record?.meeting.id, "live")
        try store.append([Segment(speaker: .me, start: 1, end: 2, text: "Hello")], to: "live")
        model.refresh()
        XCTAssertEqual(model.record?.segments.map(\.text), ["Hello"])

        // No summary yet: Copy summary does nothing.
        model.copySummary()
        XCTAssertEqual(copied, [])

        // The meeting ends and its summary lands; refreshing still never copies by itself.
        var ended = meeting("live", "Zoom", at: t0, minutes: 3)
        try store.save(ended)
        try store.setSummary(Summary(overview: "Said hello."), for: "live")
        model.refresh()
        XCTAssertEqual(model.record?.summary?.overview, "Said hello.")
        XCTAssertEqual(copied, [])
        model.copySummary()
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue(copied[0].contains("Said hello."))
        XCTAssertFalse(copied[0].contains("Transcript"), "the copied summary carries no transcript")

        // Search narrows the list; picking another meeting opens it.
        ended.id = "other"
        ended.app = "FaceTime"
        ended.startedAt = t0.addingTimeInterval(-3600)
        try store.save(ended)
        model.query = "facetime"
        model.refresh()  // what the search runs once typing pauses (F120)
        XCTAssertEqual(model.meetings.map(\.id), ["other"])
        XCTAssertEqual(model.record?.meeting.id, "other")
        model.query = ""
        model.select("live")
        XCTAssertEqual(model.record?.meeting.id, "live")
    }

    // F71: notes typed while the call records are saved as typed, and once the summary lands they are merged into
    // it without an LLM: shown first, my typed task first among the action items, and the merge follows later edits.
    func testNotesTypedDuringTheMeetingAreSavedAndMergedIntoTheSummary() throws {
        let store = InMemoryMeetingStore()
        var copied: [String] = []
        let model = MeetingsModel(store: store, copy: { copied.append($0) })
        try store.save(meeting("live", "Zoom", at: t0, minutes: nil))
        model.refresh()

        model.setNotes("Send the deck to Kate by Friday", for: "live")
        XCTAssertEqual(try store.get("live")?.notes, "Send the deck to Kate by Friday", "saved as typed")
        XCTAssertEqual(model.record?.notes, "Send the deck to Kate by Friday")
        XCTAssertNil(model.record?.summary, "no summary while it records")
        XCTAssertTrue(model.canCopySummary, "the notes alone are worth copying")

        try store.save(meeting("live", "Zoom", at: t0, minutes: 3))
        let written = Summary(overview: "Deck review.", actionItems: [ActionItem(owner: "Others", task: "review the deck")])
        try store.setSummary(written, for: "live")
        model.refresh()
        XCTAssertEqual(model.record?.summary?.actionItems, [ActionItem(owner: "Me", task: "Send the deck to Kate", due: "Friday"),
                                                            ActionItem(owner: "Others", task: "review the deck")])
        XCTAssertEqual(try store.get("live")?.summary, written, "the store keeps the summary as written")

        // Edited after the meeting: the merge reruns at once.
        model.setNotes("TODO: book the retro", for: "live")
        XCTAssertEqual(model.record?.summary?.actionItems.first, ActionItem(owner: "Me", task: "book the retro"))
        XCTAssertFalse(model.record?.summary?.actionItems.contains { $0.task.contains("Kate") } ?? true)
        XCTAssertEqual(copied, [], "typing never writes the clipboard")
        model.copySummary()
        XCTAssertTrue(copied.last?.contains("## Your notes\n\n- TODO: book the retro") ?? false)
        XCTAssertTrue(copied.last?.contains("- [ ] **Me**: book the retro") ?? false)

        // A store that refuses says so instead of losing the notes silently.
        model.setNotes("x", for: "gone")
        XCTAssertTrue(model.message.hasPrefix("Notes not saved"))
    }

    // F81: Wispr Flow's choices (keep, or 1 to 365 days), and a meeting whose transcript went says when and after
    // how long, while its summary and notes stay worth copying.
    func testDeletedTranscriptSaysAfterHowManyDaysAndTheSummaryStays() throws {
        XCTAssertEqual(TranscriptRetention.choices, [0, 1, 7, 30, 90, 180, 365])
        XCTAssertEqual(TranscriptRetention.choices.map(TranscriptRetention.label),
                       ["Keep transcripts", "Delete transcripts after 1 day", "Delete transcripts after 7 days",
                        "Delete transcripts after 30 days", "Delete transcripts after 90 days",
                        "Delete transcripts after 180 days", "Delete transcripts after 365 days"])
        XCTAssertNil(MeetingFormat.transcriptDeleted(record), "kept")
        var r = record
        let ended = try XCTUnwrap(r.meeting.endedAt)
        r.transcriptDeletedAt = ended.addingTimeInterval(86_400 + 1_800)  // the hourly sweep after 1 day
        XCTAssertEqual(MeetingFormat.transcriptDeleted(r, timeZone: utc)?.title, "Transcript deleted after 1 day")
        XCTAssertEqual(MeetingFormat.transcriptDeleted(r, timeZone: utc)?.detail,
                       "Deleted on 21.10.26, as set in Settings under Meeting transcripts. The summary and your notes stay.")
        r.transcriptDeletedAt = ended.addingTimeInterval(7 * 86_400 + 60)
        XCTAssertEqual(MeetingFormat.transcriptDeleted(r, timeZone: utc)?.title, "Transcript deleted after 7 days")

        let store = InMemoryMeetingStore([record])
        let model = MeetingsModel(store: store, copy: { _ in })
        XCTAssertEqual(try store.applyTranscriptRetention(days: 1, recording: nil, now: ended.addingTimeInterval(86_401)), ["a"])
        model.refresh()
        let shown = try XCTUnwrap(model.record)
        XCTAssertEqual(shown.segments, [])
        XCTAssertEqual(MeetingFormat.transcriptDeleted(shown, timeZone: utc)?.title, "Transcript deleted after 1 day")
        XCTAssertEqual(shown.summary?.overview, "The beta ships on Friday.")
        XCTAssertTrue(model.canCopySummary)
        XCTAssertFalse(MeetingFormat.markdown(shown, timeZone: utc).contains("## Transcript"))
    }

    // F78: All lists every meeting; Folders lists the open folder's, newest first. A meeting can be in two folders,
    // and deleting a folder leaves its meetings in All. Search in the Folders tab stays in the open folder, and a
    // meeting the folder hides still opens (Open in Meetings) by going back to All.
    func testFoldersTabListsTheOpenFolderAndScopesTheSearch() throws {
        let store = InMemoryMeetingStore()
        for (id, app, h) in [("old", "Zoom", 0.0), ("mid", "FaceTime", 1), ("new", "Teams", 2)] {
            try store.save(meeting(id, app, at: t0.addingTimeInterval(h * 3600)))
            try store.append([Segment(speaker: .others, start: 1, end: 2, text: "the \(id) budget is fine")], to: id)
        }
        let model = MeetingsModel(store: store, copy: { _ in })
        model.refresh()
        XCTAssertEqual(model.meetings.map(\.id), ["new", "mid", "old"])

        model.createFolder("Clients")
        let clients = try XCTUnwrap(model.folderID)
        XCTAssertEqual(model.tab, .folders, "a new folder opens")
        XCTAssertEqual(model.meetings, [])
        XCTAssertNil(model.record)
        model.toggle("old", in: clients)
        model.toggle("new", in: clients)
        model.toggle("mid", in: clients)
        model.toggle("mid", in: clients)  // and out again
        XCTAssertEqual(model.meetings.map(\.id), ["new", "old"])
        XCTAssertEqual(model.folders.map(\.name), ["Clients"])

        model.query = "budget"
        model.refresh()
        XCTAssertEqual(model.meetings.map(\.id), ["new", "old"], "only the folder's")
        XCTAssertEqual(model.snippets["old"], "the old budget is fine")
        model.tab = .all
        XCTAssertEqual(model.meetings.map(\.id), ["new", "mid", "old"])
        model.query = ""
        model.refresh()
        XCTAssertEqual(model.snippets["old"], "")

        model.createFolder("Beta")
        let beta = try XCTUnwrap(model.folderID)
        model.toggle("old", in: beta)
        XCTAssertEqual(model.folders.map(\.name), ["Beta", "Clients"])
        XCTAssertEqual(model.folders.filter { $0.meetingIDs.contains("old") }.count, 2, "old is in both")
        model.renameFolder(beta, to: "Launch")
        XCTAssertEqual(model.folders.map(\.name), ["Clients", "Launch"])
        model.deleteFolder(beta)
        XCTAssertEqual(model.folderID, clients, "the next folder opens")
        XCTAssertEqual(model.meetings.map(\.id), ["new", "old"], "old stays in Clients")
        model.openFolder(clients)
        model.select("mid")  // not in Clients
        XCTAssertEqual(model.tab, .all)
        XCTAssertEqual(model.record?.meeting.id, "mid")
        model.tab = .all
        XCTAssertEqual(model.meetings.count, 3, "deleting a folder deletes no meeting")

        model.createFolder("  ")
        XCTAssertTrue(model.message.hasPrefix("Folder not created"), model.message)
    }

    // F120: typing "zoo" asks the store once, after the pause, not once per letter. The pause is injected and held
    // open, so the test needs no clock.
    func testTypingAsksTheStoreOnceItPauses() async throws {
        let store = InMemoryMeetingStore()
        try store.save(meeting("a", "Zoom", at: t0))
        try store.save(meeting("b", "Teams", at: t0))
        var held: [CheckedContinuation<Void, Never>] = []
        let model = MeetingsModel(store: store, copy: { _ in }, pause: { await withCheckedContinuation { held.append($0) } })
        model.query = "z"
        model.query = "zo"
        model.query = "zoo"
        for _ in 0..<1_000 where held.count < 3 { await Task.yield() }
        XCTAssertEqual(held.count, 3)
        XCTAssertEqual(store.searches, 0, "no keystroke asks the store at once")
        held.forEach { $0.resume() }
        for _ in 0..<1_000 where store.searches == 0 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }  // room for a second, wrong query
        XCTAssertEqual(store.searches, 1)
        XCTAssertEqual(model.meetings.map(\.id), ["a"])
    }
}
