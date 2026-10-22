import AppKit
import ShepetalCore
import ShepetalSummary
import SwiftUI
import UniformTypeIdentifiers

/// The Meetings tab: All or one folder's meetings on the left, the open meeting's summary, notes and live transcript
/// on the right.
@MainActor
final class MeetingsModel: ObservableObject {
    enum Tab: String, CaseIterable { case all = "All", folders = "Folders" }

    let store: MeetingStoring
    private let copy: (String) -> Void
    private let pause: () async throws -> Void
    private var pending: Task<Void, Never>?
    /// What the list was searched for: `query` once typing pauses. The poll searches for this, never a half-typed word.
    private var searched = ""
    /// The store's write count, the tab, folder and query the list was read for; the poll skips the ranked search
    /// while none of them changed.
    private var listed: [String]?

    @Published var query = "" { didSet { searchSoon() } }
    @Published var tab = Tab.all { didSet { refresh() } }
    /// The folder the Folders tab shows; its first folder until one is picked.
    @Published private(set) var folderID: String?
    @Published private(set) var folders: [MeetingFolder] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var meetings: [Meeting] = []
    /// The text around each search match, by meeting id; "" with no query.
    @Published private(set) var snippets: [String: String] = [:]
    @Published private(set) var record: MeetingRecord?
    @Published private(set) var message = ""
    /// F123: show meetings held in another script in Latin letters (MeetingAsk.swift). For this session only.
    @Published var latin = false
    /// F73: the transcript line an answer was clicked on; the meeting's transcript opens there.
    @Published var jump: TranscriptJump?
    /// F73: the Ask pane's questions and answers, kept for the session.
    lazy var ask = MeetingAskModel(store: store)
    var latinCache: (original: MeetingRecord, latin: MeetingRecord)?

    /// `copy` writes the general pasteboard; tests pass their own. It runs only from the Copy summary button.
    /// `pause` is how long typing in the search field has to stop before the store is asked; tests pass their own.
    init(store: MeetingStoring, copy: @escaping (String) -> Void = { text in
        NSPasteboard.general.clearOnThisMac()
        NSPasteboard.general.setString(text, forType: .string)
    }, pause: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.store = store
        self.copy = copy
        self.pause = pause
    }

    /// F120: each keystroke restarts the pause, so typing a word asks the store once, not once per letter.
    private func searchSoon() {
        pending?.cancel()
        pending = Task { [weak self, pause] in
            guard (try? await pause()) != nil, !Task.isCancelled else { return }
            self?.searchNow()
        }
    }

    /// Searches for what is in the field now: the pause is over.
    func searchNow() {
        searched = query
        refresh()
    }

    /// Re-reads the folders, the list and the open meeting. It publishes only what changed, so the view can poll it.
    func refresh() {
        do {
            let f = try store.folders()
            if f != folders { folders = f }
            if tab == .folders, !f.contains(where: { $0.id == folderID }) { folderID = f.first?.id }
            let folder = tab == .folders ? folderID : nil
            // The count is read before the search, so a write during it shows on the next poll.
            let key = [String(store.changes), tab.rawValue, folder ?? "", searched]
            if key != listed {
                let hits = tab == .folders && folder == nil ? [] : try store.search(searched, folder: folder, limit: 200)
                let list = hits.map(\.meeting)
                if list != meetings { meetings = list }
                let s = Dictionary(hits.map { ($0.meeting.id, $0.snippet) }, uniquingKeysWith: { a, _ in a })
                if s != snippets { snippets = s }
                listed = key
            }
            if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) { selectedID = meetings.first?.id }
            var r = try selectedID.flatMap(store.get)
            // Shown, copied and exported: the summary with the notes merged in. The store keeps the summary as it
            // was written, so the merge reruns whenever the notes change, also after the meeting.
            if let s = r?.summary, let notes = r?.notes { r?.summary = Self.merge(s, notes) }
            if r != record { record = r }
        } catch {
            message = "Meetings: \(error.localizedDescription)"
        }
    }

    func select(_ id: String?) {
        guard let id, id != selectedID else { return }
        // Open in Meetings can ask for a meeting the open folder or the search hides: All, unfiltered, then.
        // Hub.showMeeting empties the field first, so the search to undo is the one the list shows.
        if !meetings.contains(where: { $0.id == id }) {
            if !query.isEmpty { query = "" }
            pending?.cancel()
            searched = ""
            if tab != .all { tab = .all }
        }
        selectedID = id
        message = ""  // "copied" was about the other meeting
        refresh()
    }

    func openFolder(_ id: String) {
        folderID = id
        refresh()
    }

    /// F78. A new folder opens in the Folders tab.
    func createFolder(_ name: String) {
        change("Folder not created") {
            folderID = try store.createFolder(name).id
            tab = .folders
        }
    }

    func renameFolder(_ id: String, to name: String) { change("Folder not renamed") { try store.renameFolder(id, to: name) } }

    /// Its meetings stay in All and in their other folders.
    func deleteFolder(_ id: String) { change("Folder not deleted") { try store.deleteFolder(id) } }

    /// Puts the meeting in the folder, or takes it out when it is in it already; its other folders stay.
    func toggle(_ meetingID: String, in folderID: String) {
        change("Folders not saved") {
            var ids = Set(folders.filter { $0.meetingIDs.contains(meetingID) }.map(\.id))
            if ids.remove(folderID) == nil { ids.insert(folderID) }
            try store.setFolders(ids, for: meetingID)
        }
    }

    private func change(_ failure: String, _ body: () throws -> Void) {
        do {
            try body()
            refresh()
        } catch {
            message = "\(failure): \(error.localizedDescription)"
        }
    }

    /// The non-LLM merge (rule 6). Without the bundled weights the summary stays as written; the notes still show.
    private static let summarizer = try? MeetingSummarizer()
    static func merge(_ summary: Summary, _ notes: String) -> Summary { summarizer?.merge(summary, notes: notes) ?? summary }

    /// The Notes pane, saved as it is typed, while the meeting records too.
    func setNotes(_ notes: String, for id: String) {
        do {
            try store.setNotes(notes, for: id)
            refresh()  // the merged summary follows at once
        } catch {
            message = "Notes not saved: \(error.localizedDescription)"
        }
    }

    /// Copy summary is greyed out until there is a summary or a note with something in it.
    var canCopySummary: Bool { !(record?.summary?.isEmpty ?? true) || !noteLines(record?.notes ?? "").isEmpty }

    func copySummary() {
        guard let r = record, canCopySummary else { return }
        copy(MeetingFormat.markdown(shown(r), transcript: false))
        message = "Summary copied"
    }

    func copyTranscript() {
        guard let r = record, !r.segments.isEmpty else { return }
        copy(MeetingFormat.transcript(shown(r)))
        message = "Transcript copied"
    }

    /// Writes the Markdown to a file the user picks. Nothing is written without the panel.
    func export() {
        guard let r = record, let markdown = exportMarkdown else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingFormat.filename(r.meeting)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
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
            Picker("Show", selection: $model.tab) {
                ForEach(MeetingsModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
            .padding(.horizontal, 10).padding(.top, 10)
            if model.tab == .folders { FolderBar(model: model).padding(.horizontal, 10).padding(.top, 8) }

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

            if model.tab == .folders && model.folders.isEmpty {
                ContentUnavailableView("No folders yet", systemImage: "folder",
                                       description: Text("Make one with New folder, then add meetings to it from their right-click menu."))
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.meetings, id: \.id) { m in
                        MeetingRow(meeting: m, snippet: model.snippets[m.id] ?? "", query: model.query).tag(m.id)
                            .contextMenu { folderMenu(m.id) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    /// A meeting's right-click menu: a check for each folder it is in. A meeting can be in several.
    @ViewBuilder private func folderMenu(_ id: String) -> some View {
        if !model.folders.isEmpty {
            Menu("Add to folder") {
                ForEach(model.folders) { f in
                    Toggle(f.name, isOn: Binding(get: { f.meetingIDs.contains(id) }, set: { _ in model.toggle(id, in: f.id) }))
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let r = model.record {
            MeetingDetail(record: r, model: model).id(r.meeting.id)
        } else if !model.query.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else if model.tab == .folders {
            ContentUnavailableView("No meetings in this folder", systemImage: "folder",
                                   description: Text("Right-click a meeting in All and choose Add to folder."))
        } else {
            ContentUnavailableView("No meetings yet", systemImage: "person.2.wave.2",
                                   description: Text("Recorded calls show up here with a live transcript and a summary written on this Mac."))
        }
    }
}

/// The Folders tab's folder picker, with New folder, Rename and Delete.
private struct FolderBar: View {
    @ObservedObject var model: MeetingsModel
    @State private var naming = ""  // the id of the folder being renamed, "" for a new one
    @State private var asking = false
    @State private var name = ""
    @State private var deleting = false

    private var open: MeetingFolder? { model.folders.first { $0.id == model.folderID } }

    var body: some View {
        HStack(spacing: 6) {
            if !model.folders.isEmpty {
                Picker("Folder", selection: Binding(get: { model.folderID ?? "" }, set: { model.openFolder($0) })) {
                    ForEach(model.folders) { Text("\($0.name) (\($0.meetingIDs.count))").tag($0.id) }
                }
                .labelsHidden()
            }
            Button { name = ""; naming = ""; asking = true } label: {
                // Its title only while there is no folder picker beside it.
                if model.folders.isEmpty { Label("New folder", systemImage: "folder.badge.plus") } else { Image(systemName: "folder.badge.plus") }
            }
            .help("New folder")
            if let f = open {
                Menu {
                    Button("Rename…") { name = f.name; naming = f.id; asking = true }
                    Button("Delete…", role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Rename or delete this folder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The id is captured when the alert opens: the buttons never read state that dismissing it may change.
        .alert(naming.isEmpty ? "New folder" : "Rename folder", isPresented: $asking, presenting: naming) { id in
            TextField("Name", text: $name)
            Button(id.isEmpty ? "Create" : "Rename") { id.isEmpty ? model.createFolder(name) : model.renameFolder(id, to: name) }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the folder “\(open?.name ?? "")”?", isPresented: $deleting) {
            Button("Delete folder", role: .destructive) { if let f = open { model.deleteFolder(f.id) } }
        } message: {
            Text("Its meetings are not deleted: they stay in All and in their other folders.")
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    /// F120: the text around the search match, its match in bold; "" with no search.
    var snippet = ""
    var query = ""

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
            if !snippet.isEmpty {
                Text(highlighted).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var highlighted: AttributedString {
        var a = AttributedString(snippet)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty, let r = a.range(of: q, options: .caseInsensitive) {
            a[r].inlinePresentationIntent = .stronglyEmphasized
            a[r].foregroundColor = .primary
        }
        return a
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
    enum Pane: String, CaseIterable { case summary = "Summary", notes = "Notes", transcript = "Transcript", ask = "Ask" }

    let record: MeetingRecord
    @ObservedObject var model: MeetingsModel
    @State private var pane: Pane

    init(record: MeetingRecord, model: MeetingsModel) {
        self.record = record
        self.model = model
        _pane = State(initialValue: record.summary == nil || model.jump?.meetingID == record.meeting.id ? .transcript : .summary)
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
                if model.canShowLatin { LatinToggle(model: model) }
                // Icons only when the window is too narrow for the labels.
                ViewThatFits(in: .horizontal) { actions.fixedSize(); actions.labelStyle(.iconOnly) }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)

            Divider()
            let shown = model.shown(record)  // in Latin letters when the toggle is on (F123); the Notes editor keeps the original
            switch pane {
            case .summary: SummaryPane(summary: shown.summary, notes: noteLines(shown.notes), live: live)
            case .notes: NotesPane(record: record, model: model)
            case .transcript:
                TranscriptPane(segments: shown.segments, live: live, deleted: MeetingFormat.transcriptDeleted(record),
                               target: model.jump?.meetingID == record.meeting.id ? model.jump : nil)
            case .ask: MeetingAskView(ask: model.ask, meetings: model, meetingID: record.meeting.id)
            }
        }
        .onChange(of: model.jump) { if model.jump?.meetingID == record.meeting.id { pane = .transcript } }
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
    let notes: [String]
    let live: Bool

    var body: some View {
        if let s = summary {
            ScrollView {
                SummarySections(summary: s, notes: notes)
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

/// Your notes, overview, key points, decisions and action items, empty ones left out: the sections Copy summary copies.
struct SummarySections: View {
    let summary: Summary
    var notes: [String] = []

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 26) {
            if !notes.isEmpty {
                section("Your notes") { bullets(notes, icon: "pencil", size: 11, tint: .accentColor) }
            }
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

/// A notepad for the open meeting, saved as you type, also while it records. Its lines are merged into the summary.
private struct NotesPane: View {
    let id: String
    @ObservedObject var model: MeetingsModel
    @State private var text: String

    init(record: MeetingRecord, model: MeetingsModel) {
        id = record.meeting.id
        self.model = model
        _text = State(initialValue: record.notes)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(20)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type your notes here. They are saved as you type and merged into the summary.")
                        .foregroundStyle(.tertiary).padding(.leading, 25).padding(.top, 20).allowsHitTesting(false)
                }
            }
            .onChange(of: text) { model.setNotes(text, for: id) }
    }
}

private struct TranscriptPane: View {
    let segments: [Segment]
    let live: Bool
    /// F81: the retention setting deleted it.
    var deleted: (title: String, detail: String)?
    /// An answer clicked in the Ask pane (F73): scrolled to and marked.
    var target: TranscriptJump?

    var body: some View {
        if segments.isEmpty, let deleted {
            ContentUnavailableView(deleted.title, systemImage: "clock.badge.xmark", description: Text(deleted.detail))
        } else if segments.isEmpty {
            ContentUnavailableView(live ? "Listening…" : "No transcript", systemImage: "waveform",
                                   description: Text(live ? "What is said appears here as the call goes on."
                                                          : "Nothing was transcribed in this meeting."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, s in Bubble(segment: s, marked: target?.segment == i).id(i) }
                    }
                    .padding(20)
                }
                .onAppear {
                    if let target { proxy.scrollTo(target.segment, anchor: .center) }
                    else if live { proxy.scrollTo(segments.count - 1, anchor: .bottom) }
                }
                .onChange(of: target) { if let target { withAnimation { proxy.scrollTo(target.segment, anchor: .center) } } }
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
    /// The line an answer pointed at (F73).
    var marked = false

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
                .overlay { if marked { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.accentColor, lineWidth: 2) } }
        }
        .frame(maxWidth: 480, alignment: me ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: me ? .trailing : .leading)
    }
}

/// Settings' "Meeting transcripts" (F81): keep them, or delete them some days after the meeting. A change applies at
/// once; App's hourly retention keeps applying it. A meeting still recording has no end yet, so no choice reaches it.
struct TranscriptRetentionPicker: View {
    let store: MeetingStoring
    @AppStorage(TranscriptRetention.key) private var days = 0
    @State private var problem = ""

    var body: some View {
        Picker("Meeting transcripts", selection: $days) {
            ForEach(TranscriptRetention.choices, id: \.self) { Text(TranscriptRetention.label($0)).tag($0) }
        }
        .onChange(of: days) {
            do { try store.applyTranscriptRetention(days: days, recording: nil); problem = "" }
            catch { problem = "Transcripts not deleted: \(error.localizedDescription)" }
        }
        Text("Only what was said goes. The summary, your notes and folders stay, and the audio follows Recordings.")
            .font(.caption).foregroundStyle(.secondary)
        if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange) }
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
