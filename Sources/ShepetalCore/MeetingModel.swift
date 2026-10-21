import Foundation

/// Shared meeting types: the contract between capture, transcription, storage, summary and UI.

/// One recorded meeting. Its audio is kept (rule 4) as two owner-only files, one per channel.
public struct Meeting: Codable, Equatable, Sendable {
    public var id: String
    /// What the detector reported, e.g. "Zoom" or "Google Meet (Chrome)".
    public var app: String
    public var startedAt: Date
    /// nil while the meeting is still running.
    public var endedAt: Date?
    /// The mic channel ("Me").
    public var meAudioPath: String
    /// The system audio channel ("Others").
    public var othersAudioPath: String

    public init(id: String, app: String, startedAt: Date, endedAt: Date? = nil,
                meAudioPath: String, othersAudioPath: String) {
        self.id = id
        self.app = app
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.meAudioPath = meAudioPath
        self.othersAudioPath = othersAudioPath
    }
}

/// Which channel a segment came from. The raw values are the labels shown and stored.
public enum Speaker: String, Codable, CaseIterable, Sendable {
    case me = "Me"
    case others = "Others"
}

/// One transcribed stretch of one channel. Times are seconds from `Meeting.startedAt`.
public struct Segment: Codable, Equatable, Sendable {
    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: Speaker, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct ActionItem: Codable, Equatable, Sendable {
    /// "" when no owner was found.
    public var owner: String
    public var task: String
    /// As said in the meeting ("Friday", "end of week"); "" when none.
    public var due: String

    public init(owner: String, task: String, due: String = "") {
        self.owner = owner
        self.task = task
        self.due = due
    }
}

public struct Summary: Codable, Equatable, Sendable {
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]

    public init(overview: String, keyPoints: [String] = [], decisions: [String] = [], actionItems: [ActionItem] = []) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
    }
}

/// A meeting with everything known about it, as `MeetingStoring.get` returns it.
public struct MeetingRecord: Equatable, Sendable {
    public var meeting: Meeting
    /// In time order.
    public var segments: [Segment]
    /// nil until the summary is written.
    public var summary: Summary?
    /// What the user typed in the Notes pane, as typed; "" when none.
    public var notes: String
    /// When the transcript retention (F81) deleted the segments; nil while they are kept.
    public var transcriptDeletedAt: Date?

    public init(meeting: Meeting, segments: [Segment] = [], summary: Summary? = nil, notes: String = "",
                transcriptDeletedAt: Date? = nil) {
        self.meeting = meeting
        self.segments = segments
        self.summary = summary
        self.notes = notes
        self.transcriptDeletedAt = transcriptDeletedAt
    }
}

/// A folder in the Meetings tab (F78). A meeting can be in several; deleting a folder never deletes a meeting.
public struct MeetingFolder: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var meetingIDs: Set<String>

    public init(id: String, name: String, createdAt: Date, meetingIDs: Set<String> = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.meetingIDs = meetingIDs
    }

    public struct EmptyName: Error {}

    /// The name as stored: trimmed, and never empty.
    public static func clean(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw EmptyName() }
        return n
    }
}

public extension Array where Element == MeetingFolder {
    /// The order the Folders tab lists them in.
    var byName: [MeetingFolder] {
        sorted {
            let c = $0.name.localizedStandardCompare($1.name)
            return c == .orderedSame ? $0.createdAt < $1.createdAt : c == .orderedAscending
        }
    }
}

/// A search result (F120): the meeting, and the text around the match shown under its row.
public struct MeetingHit: Equatable, Sendable {
    public var meeting: Meeting
    /// "" with no query, or when only the app name matched (the row shows it already).
    public var snippet: String

    public init(meeting: Meeting, snippet: String = "") {
        self.meeting = meeting
        self.snippet = snippet
    }

    /// At most about `width` characters of `text` around the first match of `query` in any case, on one line, cut
    /// at word edges with "…".
    public static func snippet(_ text: String, around query: String, width: Int = 64) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let r = flat.range(of: query, options: .caseInsensitive) ?? flat.startIndex..<flat.startIndex
        let before = max(0, (width - flat.distance(from: r.lowerBound, to: r.upperBound)) / 2)
        var lo = flat.index(r.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        var hi = flat.index(lo, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        // A cut inside a word moves to the next space toward the match, so no half word shows.
        if lo > flat.startIndex, !flat[flat.index(before: lo)].isWhitespace,
           let sp = flat[lo..<r.lowerBound].firstIndex(where: \.isWhitespace) { lo = flat.index(after: sp) }
        if hi < flat.endIndex, !flat[hi].isWhitespace, let sp = flat[r.upperBound..<hi].lastIndex(where: \.isWhitespace) { hi = sp }
        return (lo > flat.startIndex ? "…" : "") + flat[lo..<hi].trimmingCharacters(in: .whitespaces) + (hi < flat.endIndex ? "…" : "")
    }

    /// FTS5's snippet() on one line, without the word at a "…" cut (it cannot say whether that word is whole),
    /// unless dropping it would lose the match.
    public static func words(_ snippet: String, _ query: String) -> String {
        let flat = snippet.split(whereSeparator: \.isNewline).joined(separator: " ")
        var t = Substring(flat)
        if t.hasPrefix("…"), let sp = t.firstIndex(where: \.isWhitespace) { t = "…" + t[t.index(after: sp)...] }
        if t.hasSuffix("…"), let sp = t.lastIndex(where: \.isWhitespace) { t = t[..<sp] + "…" }
        return t.range(of: query, options: .caseInsensitive) == nil ? flat : String(t)
    }
}

/// F81: how long meeting transcripts are kept, in days; 0 keeps them (the default, as in Wispr Flow).
public enum TranscriptRetention {
    public static let key = "meetingTranscriptDays"
    public static let choices = [0, 1, 7, 30, 90, 180, 365]
    /// The Settings choice; 0 when it was never set.
    public static var days: Int { UserDefaults.standard.integer(forKey: key) }

    public static func label(_ days: Int) -> String {
        days <= 0 ? "Keep transcripts" : "Delete transcripts after \(days) day\(days == 1 ? "" : "s")"
    }
}

public protocol MeetingStoring: AnyObject {
    /// Inserts the meeting, or replaces it when the id exists (e.g. to set `endedAt`).
    func save(_ meeting: Meeting) throws
    /// Adds segments to a saved meeting; segments arrive live while it runs.
    func append(_ segments: [Segment], to meetingID: String) throws
    /// Removes these segments (one stored copy each), e.g. the call's echo on the mic channel.
    func remove(_ segments: [Segment], from meetingID: String) throws
    func setSummary(_ summary: Summary, for meetingID: String) throws
    /// Replaces the meeting's notes; works while it records too.
    func setNotes(_ notes: String, for meetingID: String) throws
    /// Goes up with every write, so a poll can tell that nothing changed since it last read.
    var changes: Int { get }
    /// Newest first.
    func list(limit: Int) throws -> [Meeting]
    /// Meetings whose app, segment text, summary or notes contains `query` (case-insensitive), in `folder` when
    /// one is given, each with a snippet of the match: best match first, then newest. An empty query lists them.
    func search(_ query: String, folder: String?, limit: Int) throws -> [MeetingHit]
    func get(_ id: String) throws -> MeetingRecord?
    /// Removes the meeting with its segments, summary, notes and folder entries (its audio files are the caller's).
    func delete(_ id: String) throws

    /// F81: deletes the segments, and their search entries, of every meeting that ended before `cutoff`, and marks
    /// them deleted at `now`. The row, summary, notes, folders and audio paths stay. `recording` and a meeting with
    /// no end are never touched. Returns the ids whose transcripts went.
    func deleteTranscripts(endedBefore cutoff: Date, recording: String?, now: Date) throws -> [String]

    // F78: folders. A meeting can be in several; deleting either one leaves the other.
    /// By name.
    func folders() throws -> [MeetingFolder]
    func createFolder(_ name: String) throws -> MeetingFolder
    func renameFolder(_ id: String, to name: String) throws
    func deleteFolder(_ id: String) throws
    /// Puts the meeting in exactly these folders.
    func setFolders(_ folderIDs: Set<String>, for meetingID: String) throws
    /// The folder's meetings, newest first.
    func list(inFolder folderID: String, limit: Int) throws -> [Meeting]
}

public extension MeetingStoring {
    /// The search without snippets or folders (MCP, the e2e check).
    func search(_ query: String, limit: Int) throws -> [Meeting] {
        try search(query, folder: nil, limit: limit).map(\.meeting)
    }

    /// F81: the transcripts of meetings that ended more than `days` days ago go; 0 (keep) deletes nothing.
    @discardableResult
    func applyTranscriptRetention(days: Int, recording: String?, now: Date = Date()) throws -> [String] {
        guard days > 0 else { return [] }
        return try deleteTranscripts(endedBefore: now.addingTimeInterval(-Double(days) * 86_400), recording: recording, now: now)
    }
}

/// Local, non-LLM summarizer (rule 6). Pure: no network, no I/O.
public protocol MeetingSummarizing {
    func summarize(_ segments: [Segment]) -> Summary
}
