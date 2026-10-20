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

    public init(meeting: Meeting, segments: [Segment] = [], summary: Summary? = nil) {
        self.meeting = meeting
        self.segments = segments
        self.summary = summary
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
    /// Newest first.
    func list(limit: Int) throws -> [Meeting]
    /// Meetings whose app, segment text or summary contains `query` (case-insensitive), newest first.
    func search(_ query: String, limit: Int) throws -> [Meeting]
    func get(_ id: String) throws -> MeetingRecord?
    /// Removes the meeting with its segments and summary (its audio files are the caller's).
    func delete(_ id: String) throws
}

/// Local, non-LLM summarizer (rule 6). Pure: no network, no I/O.
public protocol MeetingSummarizing {
    func summarize(_ segments: [Segment]) -> Summary
}
