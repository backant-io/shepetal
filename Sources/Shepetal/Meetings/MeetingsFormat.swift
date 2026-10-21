import Foundation
import ShepetalCore
import ShepetalSummary

/// Text for the Meetings tab, its Copy summary button and its Markdown export. Pure, so tests pin it down.
enum MeetingFormat {
    /// "< 1 min", "42 min", "1 h", "1 h 5 min". A running meeting counts up to `now`.
    static func duration(_ m: Meeting, now: Date = Date()) -> String {
        let minutes = Int(max(0, (m.endedAt ?? now).timeIntervalSince(m.startedAt)) / 60)
        if minutes < 1 { return "< 1 min" }
        let h = minutes / 60, mm = minutes % 60
        if h == 0 { return "\(mm) min" }
        return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
    }

    /// Offset into the meeting: "0:07", "4:07", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The summarizer leaves `owner` empty when nobody took the task.
    static func owner(_ item: ActionItem) -> String {
        let o = item.owner.trimmingCharacters(in: .whitespaces)
        return o.isEmpty ? "Unassigned" : o
    }

    static func actionLine(_ a: ActionItem) -> String {
        "- [ ] **\(owner(a))**: \(a.task)" + (a.due.isEmpty ? "" : " (due \(a.due))")
    }

    /// "2026-10-20 15:00" in `timeZone`: the same on every locale.
    static func date(_ d: Date, timeZone: TimeZone = .current, format: String = "yyyy-MM-dd HH:mm") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f.string(from: d)
    }

    /// "Zoom · 20.10.26 15:00 · 42 min" (dates as DD.MM.YY). A meeting recorded by hand has no app to name.
    static func headline(_ m: Meeting, timeZone: TimeZone = .current, now: Date = Date()) -> String {
        let app = m.app == MeetingRecorder.manualApp ? [] : [m.app]
        return (app + [date(m.startedAt, timeZone: timeZone, format: "dd.MM.yy HH:mm"), duration(m, now: now)])
            .joined(separator: " · ")
    }

    /// Copy transcript: the headline, then one plain-text line per segment with its speaker and time.
    static func transcript(_ r: MeetingRecord, timeZone: TimeZone = .current, now: Date = Date()) -> String {
        ([headline(r.meeting, timeZone: timeZone, now: now), ""]
            + r.segments.map { "\($0.speaker.rawValue) (\(clock($0.start))): \($0.text)" }).joined(separator: "\n") + "\n"
    }

    /// The Markdown file, the user's notes first. Copy summary uses it without the transcript. Empty sections are left out.
    static func markdown(_ r: MeetingRecord, transcript: Bool = true, timeZone: TimeZone = .current,
                         now: Date = Date()) -> String {
        var parts = ["# \(headline(r.meeting, timeZone: timeZone, now: now))"]
        func section(_ title: String, _ lines: [String]) {
            if !lines.isEmpty { parts.append("## \(title)\n\n" + lines.joined(separator: "\n")) }
        }
        section("Your notes", noteLines(r.notes).map { "- \($0)" })
        if let s = r.summary {
            section("Overview", s.overview.isEmpty ? [] : [s.overview])
            section("Key points", s.keyPoints.map { "- \($0)" })
            section("Decisions", s.decisions.map { "- \($0)" })
            section("Action items", s.actionItems.map(actionLine))
        }
        if transcript {
            section("Transcript", r.segments.map { "- **\($0.speaker.rawValue)** (\(clock($0.start))): \($0.text)" })
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// F81: the Transcript pane of a meeting whose transcript the retention setting deleted; nil while it is kept.
    static func transcriptDeleted(_ r: MeetingRecord, timeZone: TimeZone = .current) -> (title: String, detail: String)? {
        guard let at = r.transcriptDeletedAt else { return nil }
        let days = max(1, Int(at.timeIntervalSince(r.meeting.endedAt ?? at) / 86_400))
        return ("Transcript deleted after \(days) day\(days == 1 ? "" : "s")",
                "Deleted on \(date(at, timeZone: timeZone, format: "dd.MM.yy")), as set in Settings under Meeting transcripts. The summary and your notes stay.")
    }

    /// "Google Meet (Chrome) 2026-10-20 1500.md", with no path separators.
    static func filename(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        let app = m.app.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(app) \(date(m.startedAt, timeZone: timeZone).replacingOccurrences(of: ":", with: "")).md"
    }
}

extension Summary {
    /// The summarizer found nothing to say (no speech, or no sentence it could use).
    var isEmpty: Bool { overview.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty }
}

/// MeetingStoring kept in memory: previews, tests, and the tab until the app passes its on-disk store.
final class InMemoryMeetingStore: MeetingStoring {
    struct UnknownMeeting: Error { let id: String }
    private var records: [String: MeetingRecord] = [:] { didSet { changes += 1 } }
    private var folderList: [String: MeetingFolder] = [:] { didSet { changes += 1 } }
    private(set) var changes = 0
    /// What the tab searched for, in order (the debounce test).
    private(set) var asked: [String] = []

    init(_ records: [MeetingRecord] = []) {
        for r in records { self.records[r.meeting.id] = r }
    }

    func save(_ meeting: Meeting) throws {
        records[meeting.id, default: MeetingRecord(meeting: meeting)].meeting = meeting
    }

    func append(_ segments: [Segment], to meetingID: String) throws {
        guard records[meetingID] != nil else { throw UnknownMeeting(id: meetingID) }
        records[meetingID]!.segments += segments
    }

    func remove(_ segments: [Segment], from meetingID: String) throws {
        guard records[meetingID] != nil else { throw UnknownMeeting(id: meetingID) }
        for s in segments {
            if let i = records[meetingID]!.segments.firstIndex(of: s) { records[meetingID]!.segments.remove(at: i) }
        }
    }

    func setSummary(_ summary: Summary, for meetingID: String) throws {
        guard records[meetingID] != nil else { throw UnknownMeeting(id: meetingID) }
        records[meetingID]!.summary = summary
    }

    func setNotes(_ notes: String, for meetingID: String) throws {
        guard records[meetingID] != nil else { throw UnknownMeeting(id: meetingID) }
        records[meetingID]!.notes = notes
    }

    func list(limit: Int) throws -> [Meeting] {
        Array(records.values.map(\.meeting).sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    /// Newest first: no rank in memory.
    func search(_ query: String, folder: String?, limit: Int) throws -> [MeetingHit] {
        asked.append(query)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = records.values.compactMap { r -> MeetingHit? in
            if let folder, folderList[folder]?.meetingIDs.contains(r.meeting.id) != true { return nil }
            if q.isEmpty { return MeetingHit(meeting: r.meeting) }
            var text: [String] = [r.notes] + r.segments.map(\.text)
            if let s = r.summary {
                text += [s.overview] + s.keyPoints + s.decisions
                text += s.actionItems.flatMap { [$0.owner, $0.task, $0.due] }
            }
            if let t = text.first(where: { $0.localizedCaseInsensitiveContains(q) }) {
                return MeetingHit(meeting: r.meeting, snippet: MeetingHit.snippet(t, around: q))
            }
            return r.meeting.app.localizedCaseInsensitiveContains(q) ? MeetingHit(meeting: r.meeting) : nil
        }
        return Array(hits.sorted { $0.meeting.startedAt > $1.meeting.startedAt }.prefix(limit))
    }

    func get(_ id: String) throws -> MeetingRecord? { records[id] }

    func delete(_ id: String) throws {
        records[id] = nil
        for f in folderList.keys { folderList[f]?.meetingIDs.remove(id) }
    }

    func deleteTranscripts(endedBefore cutoff: Date, recording: String?, now: Date) throws -> [String] {
        let ids = records.values.filter {
            $0.meeting.id != recording && ($0.meeting.endedAt.map { $0 < cutoff } ?? false) && $0.transcriptDeletedAt == nil && !$0.segments.isEmpty
        }.map(\.meeting.id).sorted()
        for id in ids {
            records[id]!.segments = []
            records[id]!.transcriptDeletedAt = now
        }
        return ids
    }

    func folders() throws -> [MeetingFolder] { Array(folderList.values).byName }

    func createFolder(_ name: String) throws -> MeetingFolder {
        let f = MeetingFolder(id: UUID().uuidString, name: try MeetingFolder.clean(name), createdAt: Date())
        folderList[f.id] = f
        return f
    }

    func renameFolder(_ id: String, to name: String) throws {
        guard folderList[id] != nil else { throw UnknownMeeting(id: id) }
        folderList[id]!.name = try MeetingFolder.clean(name)
    }

    func deleteFolder(_ id: String) throws { folderList[id] = nil }

    func setFolders(_ folderIDs: Set<String>, for meetingID: String) throws {
        guard records[meetingID] != nil else { throw UnknownMeeting(id: meetingID) }
        if let unknown = folderIDs.first(where: { folderList[$0] == nil }) { throw UnknownMeeting(id: unknown) }
        for f in folderList.keys {
            if folderIDs.contains(f) { folderList[f]!.meetingIDs.insert(meetingID) } else { folderList[f]!.meetingIDs.remove(meetingID) }
        }
    }

    func list(inFolder folderID: String, limit: Int) throws -> [Meeting] {
        Array(try list(limit: Int.max).filter { folderList[folderID]?.meetingIDs.contains($0.id) == true }.prefix(limit))
    }
}
