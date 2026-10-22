import AppKit
import ShepetalCore
import ShepetalSummary
import SwiftUI

/// Where an answer was said: the Meetings tab opens that meeting's transcript at this segment (F73).
struct TranscriptJump: Equatable {
    let meetingID: String
    let segment: Int
    /// A new click on the same line scrolls there again.
    let id = UUID()
}

/// The Ask pane (F73): questions about one meeting or all of them, answered by MeetingAnswers with quoted
/// transcript lines and summary items, never with written text (rule 6). Kept for the session, not stored.
@MainActor
final class MeetingAskModel: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        /// The meeting asked about; nil for all meetings.
        let scope: String?
        let question: String
        let answer: MeetingAnswer
        /// "Zoom · 20.10.26 15:00 · 42 min" for each meeting an answer quotes.
        let headlines: [String: String]
    }

    /// Meetings the search index shortlists for a question across all meetings, and recent ones for summary questions.
    static let shortlisted = 10, recent = 20

    let store: MeetingStoring
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var message = ""

    init(store: MeetingStoring) { self.store = store }

    func turns(in scope: String?) -> [Turn] { turns.filter { $0.scope == scope } }

    /// Answers `question` about the meeting `scope`, or about all meetings when it is nil.
    func ask(_ question: String, in scope: String?) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        do {
            var ids: [String]
            if let scope {
                ids = [scope]
            } else {
                // The index ranks the meetings that mention the question's words; Swift ranks the lines within them.
                ids = try store.shortlist(MeetingAnswers.searchTerms(q), limit: Self.shortlisted)
                for m in try store.list(limit: Self.recent) where !ids.contains(m.id) { ids.append(m.id) }
            }
            let records = try ids.compactMap(store.get).map { r -> MeetingRecord in
                var r = r
                if let s = r.summary { r.summary = MeetingsModel.merge(s, r.notes) }  // what the Summary pane shows
                return r
            }
            let answer = MeetingAnswers.answer(q, in: records)
            var headlines: [String: String] = [:]
            for r in records where answer.quotes.contains(where: { $0.meetingID == r.meeting.id }) {
                headlines[r.meeting.id] = MeetingFormat.headline(r.meeting)
            }
            turns.append(Turn(scope: scope, question: q, answer: answer, headlines: headlines))
            message = ""
        } catch {
            message = "Could not search the meetings: \(error.localizedDescription)"
        }
    }

    /// Said plainly when nothing answers.
    static func nothingFound(allMeetings: Bool) -> String {
        allMeetings ? "Nothing in your meetings answers that." : "Nothing in this meeting answers that."
    }

    /// The answer's first line: an action item as "Me: send the slides (Friday)", a transcript line in quotes.
    static func line(_ q: MeetingAnswer.Quote) -> String {
        switch q.source {
        case .actionItem: "\(MeetingFormat.owner(ActionItem(owner: q.speaker, task: q.text))): \(q.text)" + (q.due.isEmpty ? "" : " (\(q.due))")
        case .transcript: "“\(q.text)”"
        case .decision, .keyPoint: q.text
        }
    }

    /// Under it: what it is, who said it and when, and in which meeting when the question was about all of them.
    static func caption(_ q: MeetingAnswer.Quote, headline: String?) -> String {
        let what: [String] = switch q.source {
        case .transcript: [q.speaker]
        case .actionItem: ["Action item"]
        case .decision: ["Decision"]
        case .keyPoint: ["Key point"]
        }
        return (what + [q.start.map(MeetingFormat.clock), headline].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension MeetingsModel {
    /// F73: opens the meeting's transcript at the line an answer quotes.
    func openTranscript(_ meetingID: String, segment: Int) {
        jump = TranscriptJump(meetingID: meetingID, segment: segment)
        select(meetingID)
    }

    /// F123: the open meeting has letters outside the Latin script, so the Latin toggle shows.
    var canShowLatin: Bool { record?.needsLatin ?? false }

    /// F123: the record as shown, copied and exported: in Latin letters when the toggle is on and it has other
    /// letters, else as stored. Computed each time (cached for the last record), never written back.
    func shown(_ r: MeetingRecord) -> MeetingRecord {
        guard latin, r.needsLatin else { return r }
        if let c = latinCache, c.original == r { return c.latin }
        let l = r.inLatin()
        latinCache = (r, l)
        return l
    }

    /// F123: one line of text as shown, e.g. a quoted answer.
    func shown(_ text: String) -> String { latin ? Romanize.latin(text) : text }

    /// What Export Markdown… writes for the open meeting; follows the Latin toggle.
    var exportMarkdown: String? { record.map { MeetingFormat.markdown(shown($0)) } }
}

/// "Latin script": shown only for meetings with letters outside the Latin script (F123).
struct LatinToggle: View {
    @ObservedObject var model: MeetingsModel

    var body: some View {
        Toggle("Latin script", isOn: $model.latin)
            .toggleStyle(.checkbox)
            .help("Show this meeting in Latin letters. Copy and export follow it. The stored transcript does not change.")
    }
}

struct MeetingAskView: View {
    @ObservedObject var ask: MeetingAskModel
    @ObservedObject var meetings: MeetingsModel
    let meetingID: String
    @State private var question = ""
    @State private var allMeetings = false

    private var scope: String? { allMeetings ? nil : meetingID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Ask about", selection: $allMeetings) {
                Text("This meeting").tag(false)
                Text("All meetings").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)

            let turns = ask.turns(in: scope)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if turns.isEmpty {
                            Text("Ask who will do what, what was decided, or what someone said about a topic. "
                                 + "Answers are lines quoted from the transcript and the summary, with who said them and when.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(turns) { turn in TurnView(turn: turn, meetings: meetings).id(turn.id) }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: turns.count) { if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }

            Divider()
            HStack(spacing: 8) {
                TextField(allMeetings ? "Ask about all meetings" : "Ask about this meeting", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Ask", action: send).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
            if !ask.message.isEmpty {
                Text(ask.message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    private func send() {
        ask.ask(question, in: scope)
        question = ""
    }
}

private struct TurnView: View {
    let turn: MeetingAskModel.Turn
    @ObservedObject var meetings: MeetingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).font(.body.weight(.semibold))
            if turn.answer.quotes.isEmpty {
                Text(MeetingAskModel.nothingFound(allMeetings: turn.scope == nil)).foregroundStyle(.secondary)
            }
            ForEach(Array(turn.answer.quotes.enumerated()), id: \.offset) { _, q in
                let row = VStack(alignment: .leading, spacing: 3) {
                    Text(meetings.shown(MeetingAskModel.line(q))).fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text(MeetingAskModel.caption(q, headline: turn.scope == nil ? turn.headlines[q.meetingID] : nil))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let segment = q.segment {
                    Button { meetings.openTranscript(q.meetingID, segment: segment) } label: { row.contentShape(Rectangle()) }
                        .buttonStyle(.plain).help("Open the transcript here")
                } else {
                    row
                }
            }
        }
    }
}
