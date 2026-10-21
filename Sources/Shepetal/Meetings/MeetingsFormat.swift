import Foundation
import ShepetalCore

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

    /// The Markdown file. Copy summary uses it without the transcript. Empty sections are left out.
    static func markdown(_ r: MeetingRecord, transcript: Bool = true, timeZone: TimeZone = .current,
                         now: Date = Date()) -> String {
        var parts = ["# \(r.meeting.app)", "\(date(r.meeting.startedAt, timeZone: timeZone)) · \(duration(r.meeting, now: now))"]
        func section(_ title: String, _ lines: [String]) {
            if !lines.isEmpty { parts.append("## \(title)\n\n" + lines.joined(separator: "\n")) }
        }
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

    /// "Google Meet (Chrome) 2026-10-20 1500.md", with no path separators.
    static func filename(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        let app = m.app.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(app) \(date(m.startedAt, timeZone: timeZone).replacingOccurrences(of: ":", with: "")).md"
    }
}

/// MeetingStoring kept in memory: previews, tests, and the tab until the app passes its on-disk store.
final class InMemoryMeetingStore: MeetingStoring {
    struct UnknownMeeting: Error { let id: String }
    private var records: [String: MeetingRecord] = [:]

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

    func list(limit: Int) throws -> [Meeting] {
        Array(records.values.map(\.meeting).sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    func search(_ query: String, limit: Int) throws -> [Meeting] {
        let hits = records.values.filter { r in
            var text: [String] = [r.meeting.app] + r.segments.map(\.text)
            if let s = r.summary {
                text += [s.overview] + s.keyPoints + s.decisions
                text += s.actionItems.flatMap { [$0.owner, $0.task, $0.due] }
            }
            return text.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return Array(hits.map(\.meeting).sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    func get(_ id: String) throws -> MeetingRecord? { records[id] }

    func delete(_ id: String) throws { records[id] = nil }
}
