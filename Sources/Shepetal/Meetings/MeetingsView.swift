import AppKit
import ShepetalCore
import SwiftUI
import UniformTypeIdentifiers

/// The Meetings tab: the list on the left, the open meeting's summary and live transcript on the right.
@MainActor
final class MeetingsModel: ObservableObject {
    let store: MeetingStoring
    private let copy: (String) -> Void

    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var selectedID: String?
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var record: MeetingRecord?
    @Published private(set) var message = ""

    /// `copy` writes the general pasteboard; tests pass their own. It runs only from the Copy summary button.
    init(store: MeetingStoring, copy: @escaping (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }) {
        self.store = store
        self.copy = copy
    }

    /// Re-reads the list and the open meeting. It publishes only what changed, so the view can poll it.
    func refresh() {
        do {
            let q = query.trimmingCharacters(in: .whitespaces)
            let list = try q.isEmpty ? store.list(limit: 200) : store.search(q, limit: 200)
            if list != meetings { meetings = list }
            if selectedID == nil || !list.contains(where: { $0.id == selectedID }) { selectedID = list.first?.id }
            let r = try selectedID.flatMap(store.get)
            if r != record { record = r }
        } catch {
            message = "Meetings: \(error.localizedDescription)"
        }
    }

    func select(_ id: String?) {
        guard let id, id != selectedID else { return }
        selectedID = id
        message = ""  // "copied" was about the other meeting
        refresh()
    }

    /// Copy summary is greyed out until there is a summary with something in it.
    var canCopySummary: Bool { !(record?.summary?.isEmpty ?? true) }

    func copySummary() {
        guard let r = record, canCopySummary else { return }
        copy(MeetingFormat.markdown(r, transcript: false))
        message = "Summary copied"
    }

    func copyTranscript() {
        guard let r = record, !r.segments.isEmpty else { return }
        copy(MeetingFormat.transcript(r))
        message = "Transcript copied"
    }

    /// Writes the Markdown to a file the user picks. Nothing is written without the panel.
    func export() {
        guard let r = record else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingFormat.filename(r.meeting)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeetingFormat.markdown(r).write(to: url, atomically: true, encoding: .utf8)
            message = "Exported \(url.lastPathComponent)"
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}

struct MeetingsView: View {
    @ObservedObject var model: MeetingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // ponytail: polls the store every second so live segments and new meetings show up; a change
        // notification from the store would replace this if it ever gets costly.
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search meetings", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)

            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.meetings, id: \.id) { MeetingRow(meeting: $0).tag($0.id) }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var detail: some View {
        if let r = model.record {
            MeetingDetail(record: r, model: model).id(r.meeting.id)
        } else if !model.query.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else {
            ContentUnavailableView("No meetings yet", systemImage: "person.2.wave.2",
                                   description: Text("Recorded calls show up here with a live transcript and a summary written on this Mac."))
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(meeting.app).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if meeting.endedAt == nil { LiveBadge() }
            }
            TimelineView(.periodic(from: .now, by: 30)) { t in
                Text("\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(MeetingFormat.duration(meeting, now: t.date))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text("Live").font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.red.opacity(0.12), in: Capsule())
    }
}

private struct MeetingDetail: View {
    enum Pane: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    let record: MeetingRecord
    @ObservedObject var model: MeetingsModel
    @State private var pane: Pane

    init(record: MeetingRecord, model: MeetingsModel) {
        self.record = record
        self.model = model
        _pane = State(initialValue: record.summary == nil ? .transcript : .summary)
    }

    private var live: Bool { record.meeting.endedAt == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(record.meeting.app).font(.title2.weight(.semibold)).lineLimit(1)
                    if live { LiveBadge() }
                }
                TimelineView(.periodic(from: .now, by: 1)) { t in
                    Text("\(record.meeting.startedAt.formatted(date: .long, time: .shortened)) · \(MeetingFormat.duration(record.meeting, now: t.date))")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)

            HStack(spacing: 8) {
                Picker("View", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                // Icons only when the window is too narrow for the labels.
                ViewThatFits(in: .horizontal) { actions.fixedSize(); actions.labelStyle(.iconOnly) }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)

            Divider()
            switch pane {
            case .summary: SummaryPane(summary: record.summary, live: live)
            case .transcript: TranscriptPane(segments: record.segments, live: live)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.copyTranscript() } label: { Label("Copy transcript", systemImage: "text.quote") }
                .disabled(record.segments.isEmpty).help("Copy transcript")
            Button { model.copySummary() } label: { Label("Copy summary", systemImage: "doc.on.doc") }
                .disabled(!model.canCopySummary).help("Copy summary")
            Button { model.export() } label: { Label("Export Markdown…", systemImage: "square.and.arrow.up") }
                .help("Export Markdown…")
        }
    }
}

private struct SummaryPane: View {
    let summary: Summary?
    let live: Bool

    var body: some View {
        if let s = summary {
            ScrollView {
                SummarySections(summary: s)
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(live ? "Summary comes after the call" : "Summary not ready yet",
                                   systemImage: "text.alignleft",
                                   description: Text("It is written on this Mac once the meeting ends."))
        }
    }
}

/// Overview, key points, decisions and action items, empty ones left out: the sections Copy summary copies.
struct SummarySections: View {
    let summary: Summary

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 26) {
            if !s.overview.isEmpty {
                section("Overview") { Text(s.overview).lineSpacing(3) }
            }
            if !s.keyPoints.isEmpty {
                section("Key points") { bullets(s.keyPoints, icon: "circle.fill", size: 5, tint: .secondary) }
            }
            if !s.decisions.isEmpty {
                section("Decisions") { bullets(s.decisions, icon: "checkmark.seal.fill", size: 12, tint: .green) }
            }
            if !s.actionItems.isEmpty {
                section("Action items") {
                    ForEach(Array(s.actionItems.enumerated()), id: \.offset) { _, a in ActionRow(item: a) }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func bullets(_ lines: [String], icon: String, size: CGFloat, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon).font(.system(size: size)).foregroundStyle(tint).frame(width: 14)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct ActionRow: View {
    let item: ActionItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.task).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label(MeetingFormat.owner(item), systemImage: "person.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.owner.isEmpty ? .secondary : .primary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary.opacity(0.7), in: Capsule())
                    if !item.due.isEmpty {
                        Label(item.due, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TranscriptPane: View {
    let segments: [Segment]
    let live: Bool

    var body: some View {
        if segments.isEmpty {
            ContentUnavailableView(live ? "Listening…" : "No transcript", systemImage: "waveform",
                                   description: Text(live ? "What is said appears here as the call goes on."
                                                          : "Nothing was transcribed in this meeting."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, s in Bubble(segment: s).id(i) }
                    }
                    .padding(20)
                }
                .onAppear { if live { proxy.scrollTo(segments.count - 1, anchor: .bottom) } }
                // ponytail: always follows the newest line while live, even if the user scrolled up.
                .onChange(of: segments.count) {
                    if live { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(segments.count - 1, anchor: .bottom) } }
                }
            }
        }
    }
}

struct Bubble: View {
    let segment: Segment

    var body: some View {
        let me = segment.speaker == .me
        VStack(alignment: me ? .trailing : .leading, spacing: 3) {
            Text("\(segment.speaker.rawValue) · \(MeetingFormat.clock(segment.start))")
                .font(.caption).foregroundStyle(.secondary)
            Text(segment.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(me ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: 480, alignment: me ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: me ? .trailing : .leading)
    }
}

#if DEBUG
struct MeetingsView_Previews: PreviewProvider {
    static var previews: some View {
        let start = Date().addingTimeInterval(-42 * 60)
        let done = MeetingRecord(
            meeting: Meeting(id: "a", app: "Zoom", startedAt: start.addingTimeInterval(-86_400),
                             endedAt: start.addingTimeInterval(-86_400 + 1_800), meAudioPath: "", othersAudioPath: ""),
            segments: [Segment(speaker: .others, start: 3, end: 8, text: "Shall we ship the beta on Friday?"),
                       Segment(speaker: .me, start: 9, end: 14, text: "Yes. I will send the release notes tomorrow.")],
            summary: Summary(overview: "The team agreed to ship the beta on Friday.",
                             keyPoints: ["Beta is feature complete", "Two open bugs remain"],
                             decisions: ["Ship the beta on Friday"],
                             actionItems: [ActionItem(owner: "Me", task: "Send the release notes", due: "tomorrow"),
                                           ActionItem(owner: "", task: "Fix the two open bugs")]))
        let running = MeetingRecord(
            meeting: Meeting(id: "b", app: "Google Meet (Chrome)", startedAt: start, meAudioPath: "", othersAudioPath: ""),
            segments: [Segment(speaker: .others, start: 2, end: 5, text: "Can everyone hear me?"),
                       Segment(speaker: .me, start: 6, end: 7, text: "Loud and clear.")])
        MeetingsView(model: MeetingsModel(store: InMemoryMeetingStore([done, running]), copy: { _ in }))
            .frame(width: 900, height: 600)
    }
}
#endif
