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

/// The tab in shepetal UI: the list of meetings on the left (one entry per meeting, mono meta, a hairline below,
/// the open one on the sunken ground), the open meeting on the right. A meeting that records is the view's one
/// signal mark: on its entry, or in the detail's title when it is the open one.
struct MeetingsView: View {
    @ObservedObject var model: MeetingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280).shHairline(.trailing)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SH.bg)
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
        VStack(alignment: .leading, spacing: SH.space3) {
            SHSegmented("Show", selection: $model.tab, options: MeetingsModel.Tab.allCases.map { (value: $0, label: $0.rawValue) })
            if model.tab == .folders { FolderBar(model: model) }
            MeetingSearchField(query: $model.query)

            if model.tab == .folders && model.folders.isEmpty {
                MeetingsEmpty("No folders yet", icon: .folder,
                              detail: "Make one with New folder, then add meetings to it from their right-click menu.")
            } else {
                MeetingList(model: model)
            }
        }
        .padding(.top, SH.space4)
        .padding(.horizontal, SH.space3)
    }

    @ViewBuilder private var detail: some View {
        if let r = model.record {
            MeetingDetail(record: r, model: model).id(r.meeting.id)
        } else if !model.query.isEmpty {
            MeetingsEmpty("No results for “\(model.query)”", icon: .search, detail: "Check the spelling or try a new search.")
        } else if model.tab == .folders {
            MeetingsEmpty("No meetings in this folder", icon: .folder,
                          detail: "Right-click a meeting in All and choose Add to folder.")
        } else {
            MeetingsEmpty("No meetings yet", icon: .users,
                          detail: "Recorded calls show up here with a live transcript and a summary written on this Mac.")
        }
    }
}

/// An empty pane: a 20 pt icon, what is missing, and the way to fill it.
struct MeetingsEmpty: View {
    let title: String
    let icon: SHIconName
    let detail: String

    init(_ title: String, icon: SHIconName, detail: String) {
        self.title = title
        self.icon = icon
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: SH.space2) {
            SHIcon(icon, size: 20).foregroundStyle(SH.textMuted).padding(.bottom, SH.space1)
            Text(title).shText(SH.appHeading).foregroundStyle(SH.text)
            Text(detail).shText(SH.appSmall).foregroundStyle(SH.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .padding(SH.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The search field: a field-ground input with the search icon, and a quiet clear button while it holds text.
private struct MeetingSearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: SH.space2) {
            SHIcon(.search).foregroundStyle(SH.textMuted)
            TextField("Search meetings", text: $query)
                .textFieldStyle(.plain)
                .shText(SH.appBody)
                .foregroundStyle(SH.text)
                .focused($focused)
            if !query.isEmpty {
                Button { query = "" } label: { SHIcon(.x).foregroundStyle(SH.textMuted).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: SH.controlMd)
        .background(SH.bgField, in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous)
            .strokeBorder(hover ? SH.textMuted : SH.borderStrong, lineWidth: 1))
        .shFocusRing(focused)
        .onHover { hover = $0 }
    }
}

/// The meetings as entries, newest first. ↑ and ↓ open the one above or below, as the system list did.
private struct MeetingList: View {
    @ObservedObject var model: MeetingsModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.meetings, id: \.id) { m in
                        MeetingRow(meeting: m, snippet: model.snippets[m.id] ?? "", query: model.query,
                                   selected: m.id == model.selectedID) { model.select(m.id); focused = true }
                            .id(m.id)
                            .contextMenu { folderMenu(m.id) }
                    }
                }
                .shHairline(.top)
                .padding(.bottom, SH.space3)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1, proxy) }
            .onKeyPress(.upArrow) { step(-1, proxy) }
        }
    }

    private func step(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = model.meetings.map(\.id)
        guard let i = ids.firstIndex(where: { $0 == model.selectedID }), ids.indices.contains(i + by) else { return .ignored }
        model.select(ids[i + by])
        proxy.scrollTo(ids[i + by])
        return .handled
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
        HStack(spacing: SH.space2) {
            if let f = open {
                Menu {
                    ForEach(model.folders) { folder in
                        Button("\(folder.name) (\(folder.meetingIDs.count))") { model.openFolder(folder.id) }
                    }
                } label: {
                    HStack(spacing: SH.space2) {
                        Text("\(f.name) (\(f.meetingIDs.count))").lineLimit(1)
                        SHIcon(.chevronDown).foregroundStyle(SH.textMuted)
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.keycap(.secondary, .sm))
                .accessibilityLabel("Folder")
                .accessibilityValue(f.name)
            }
            Button { name = ""; naming = ""; asking = true } label: {
                // Its title only while there is no folder picker beside it.
                if model.folders.isEmpty { Label { Text("New folder") } icon: { SHIcon(.folderPlus) } } else { SHIcon(.folderPlus) }
            }
            .buttonStyle(.keycap(model.folders.isEmpty ? .secondary : .quiet, .sm))
            .help("New folder")
            .accessibilityLabel("New folder")
            if let f = open {
                Menu {
                    Button("Rename…") { name = f.name; naming = f.id; asking = true }
                    Button("Delete…", role: .destructive) { deleting = true }
                } label: { SHIcon(.ellipsis) }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.keycap(.quiet, .sm))
                    .fixedSize()
                    .help("Rename or delete this folder")
                    .accessibilityLabel("Rename or delete this folder")
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

/// One meeting in the list, as a History entry: its name and length, when it started in mono, and the search match.
private struct MeetingRow: View {
    let meeting: Meeting
    /// F120: the text around the search match, its match in bold; "" with no search.
    var snippet = ""
    var query = ""
    var selected = false
    let open: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: SH.space2) {
                    Text(meeting.app).shText(SH.appStrong).foregroundStyle(SH.text).lineLimit(1)
                    Spacer(minLength: SH.space1)
                    // The open meeting shows Live in the detail, so the view keeps one signal mark.
                    if meeting.endedAt == nil { LiveMark(signal: !selected) }
                    TimelineView(.periodic(from: .now, by: 30)) { t in
                        Text(MeetingFormat.duration(meeting, now: t.date)).shText(SH.label).foregroundStyle(SH.textMuted)
                            .lineLimit(1).fixedSize()
                    }
                }
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .shText(SH.label).foregroundStyle(SH.textMuted).lineLimit(1)
                if !snippet.isEmpty {
                    Text(highlighted).shText(SH.appSmall).foregroundStyle(SH.textMuted).lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ground }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .shFocusRing(focused)
        .shHairline(.bottom)
        .onHover { inside in withAnimation(SH.settle(reduce: reduceMotion)) { hover = inside } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var ground: some View {
        if selected {
            Rectangle().fill(SH.bgSunken)
        } else if hover {
            Rectangle().fill(SH.text(scheme).opacity(0.04))
        }
    }

    private var highlighted: AttributedString {
        var a = AttributedString(snippet)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty, let r = a.range(of: q, options: .caseInsensitive) {
            a[r].font = SH.appSmall.with(weight: 600).font
            a[r].foregroundColor = SH.text(scheme)
        }
        return a
    }
}

/// A meeting that records: "Live" in mono, with a signal square when it is the view's one signal mark.
private struct LiveMark: View {
    var signal = true

    var body: some View {
        HStack(spacing: 6) {
            if signal {
                RoundedRectangle(cornerRadius: SH.radiusXs, style: .continuous).fill(SH.signal).frame(width: 8, height: 8)
            }
            Text("Live").shText(SH.label).foregroundStyle(SH.textMuted)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct MeetingDetail: View {
    enum Pane: String, CaseIterable { case summary = "Summary", notes = "Notes", transcript = "Transcript" }

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
            VStack(alignment: .leading, spacing: SH.space1) {
                HStack(alignment: .firstTextBaseline, spacing: SH.space3) {
                    Text(record.meeting.app).shText(SH.appTitle).foregroundStyle(SH.text).lineLimit(1)
                    if live { LiveMark() }
                }
                TimelineView(.periodic(from: .now, by: 1)) { t in
                    Text("\(record.meeting.startedAt.formatted(date: .long, time: .shortened)) · \(MeetingFormat.duration(record.meeting, now: t.date))")
                        .shText(SH.label).foregroundStyle(SH.textMuted).lineLimit(1)
                }
                if !model.message.isEmpty {
                    Text(model.message).shText(SH.appSmall).foregroundStyle(SH.textMuted).lineLimit(1)
                }
            }
            .padding(.horizontal, SH.space5).padding(.top, SH.space5).padding(.bottom, SH.space4)

            HStack(spacing: SH.space2) {
                SHSegmented("View", selection: $pane, options: Pane.allCases.map { (value: $0, label: $0.rawValue) }).fixedSize()
                Spacer(minLength: SH.space2)
                // Icons only when the window is too narrow for the labels.
                ViewThatFits(in: .horizontal) { actions(iconOnly: false).fixedSize(); actions(iconOnly: true) }
            }
            .padding(.horizontal, SH.space5).padding(.bottom, SH.space3)

            Rectangle().fill(SH.border).frame(height: 1)
            switch pane {
            case .summary: SummaryPane(summary: record.summary, notes: noteLines(record.notes), live: live)
            case .notes: NotesPane(record: record, model: model)
            case .transcript: TranscriptPane(segments: record.segments, live: live, deleted: MeetingFormat.transcriptDeleted(record))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func actions(iconOnly: Bool) -> some View {
        HStack(spacing: SH.space1) {
            MeetingTool("Copy transcript", icon: .textQuote, iconOnly: iconOnly) { model.copyTranscript() }
                .disabled(record.segments.isEmpty)
            MeetingTool("Copy summary", icon: .copy, iconOnly: iconOnly) { model.copySummary() }
                .disabled(!model.canCopySummary)
            MeetingTool("Export Markdown…", icon: .share, iconOnly: iconOnly) { model.export() }
        }
    }
}

/// A quiet tool button with a 16 pt icon, its title hidden when there is no room; the title is always its name.
struct MeetingTool: View {
    let title: String
    let icon: SHIconName
    var iconOnly = false
    var variant: SHKeycapStyle.Variant = .quiet
    let action: () -> Void

    init(_ title: String, icon: SHIconName, iconOnly: Bool = false, variant: SHKeycapStyle.Variant = .quiet,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.iconOnly = iconOnly
        self.variant = variant
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if iconOnly { SHIcon(icon) } else { Label { Text(title) } icon: { SHIcon(icon) } }
        }
        .buttonStyle(.keycap(variant, .sm))
        .help(title)
        .accessibilityLabel(title)
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
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(SH.space5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            MeetingsEmpty(live ? "Summary comes after the call" : "Summary not ready yet", icon: .textAlignStart,
                          detail: "It is written on this Mac once the meeting ends.")
        }
    }
}

/// Your notes, overview, key points, decisions and action items, empty ones left out: the sections Copy summary copies.
struct SummarySections: View {
    let summary: Summary
    var notes: [String] = []

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: SH.space5) {
            if !notes.isEmpty {
                section("Your notes") { bullets(notes) { SHIcon(.pencil).foregroundStyle(SH.textMuted) } }
            }
            if !s.overview.isEmpty {
                section("Overview") { Text(s.overview).shText(SH.appBody).foregroundStyle(SH.text) }
            }
            if !s.keyPoints.isEmpty {
                section("Key points") {
                    bullets(s.keyPoints) {
                        RoundedRectangle(cornerRadius: 1).fill(SH.textMuted).frame(width: 4, height: 4)
                            .frame(width: 16, height: 16)
                    }
                }
            }
            if !s.decisions.isEmpty {
                section("Decisions") { bullets(s.decisions) { SHIcon(.check).foregroundStyle(SH.text) } }
            }
            if !s.actionItems.isEmpty {
                section("Action items") {
                    VStack(alignment: .leading, spacing: SH.space3) {
                        ForEach(Array(s.actionItems.enumerated()), id: \.offset) { _, a in ActionRow(item: a) }
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).shText(SH.appHeading).foregroundStyle(SH.text)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func bullets<Mark: View>(_ lines: [String], @ViewBuilder mark: @escaping () -> Mark) -> some View {
        VStack(alignment: .leading, spacing: SH.space2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 10) {
                    mark().padding(.top, 2)
                    Text(line).shText(SH.appBody).foregroundStyle(SH.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One action item: the task, then who owns it and when it is due as mono labels.
struct ActionRow: View {
    let item: ActionItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SHIcon(.circle).foregroundStyle(SH.textMuted).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task).shText(SH.appBody).foregroundStyle(SH.text).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SH.space3) {
                    Text(MeetingFormat.owner(item))
                    if !item.due.isEmpty { Text("due \(item.due)") }
                }
                .shText(SH.label)
                .foregroundStyle(SH.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A notepad for the open meeting, saved as you type, also while it records. Its lines are merged into the summary.
private struct NotesPane: View {
    let id: String
    @ObservedObject var model: MeetingsModel
    @State private var text: String
    @FocusState private var focused: Bool

    init(record: MeetingRecord, model: MeetingsModel) {
        id = record.meeting.id
        self.model = model
        _text = State(initialValue: record.notes)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(SH.appBody.font)
            .lineSpacing(SH.appBody.lineSpacing)
            .foregroundStyle(SH.text)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .focusEffectDisabled()
            .padding(SH.space3)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type your notes here. They are saved as you type and merged into the summary.")
                        .shText(SH.appBody).foregroundStyle(SH.textMuted)
                        .padding(.leading, SH.space3 + 5).padding(.top, SH.space3)
                        .allowsHitTesting(false)
                }
            }
            .background(SH.bgField, in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous).strokeBorder(SH.borderStrong, lineWidth: 1))
            .shFocusRing(focused)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(SH.space5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: text) { model.setNotes(text, for: id) }
    }
}

private struct TranscriptPane: View {
    let segments: [Segment]
    let live: Bool
    /// F81: the retention setting deleted it.
    var deleted: (title: String, detail: String)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if segments.isEmpty, let deleted {
            MeetingsEmpty(deleted.title, icon: .clockAlert, detail: deleted.detail)
        } else if segments.isEmpty {
            MeetingsEmpty(live ? "Listening…" : "No transcript", icon: .captions,
                          detail: live ? "What is said appears here as the call goes on." : "Nothing was transcribed in this meeting.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: SH.space3) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, s in Bubble(segment: s).id(i) }
                    }
                    .frame(maxWidth: 720)
                    .padding(SH.space5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { if live { proxy.scrollTo(segments.count - 1, anchor: .bottom) } }
                // ponytail: always follows the newest line while live, even if the user scrolled up.
                .onChange(of: segments.count) {
                    withAnimation(SH.motion(SH.easeMove, SH.durBase, reduce: reduceMotion)) {
                        if live { proxy.scrollTo(segments.count - 1, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

/// One thing said: who and when in mono, then the words. Others on the raised ground at the left, Me on the sunken
/// ground at the right; a hairline edge, no shadow.
struct Bubble: View {
    let segment: Segment

    var body: some View {
        let me = segment.speaker == .me
        VStack(alignment: me ? .trailing : .leading, spacing: SH.space1) {
            Text("\(segment.speaker.rawValue) · \(MeetingFormat.clock(segment.start))")
                .shText(SH.label).foregroundStyle(SH.textMuted)
            Text(segment.text)
                .shText(SH.appBody)
                .foregroundStyle(SH.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SH.space3).padding(.vertical, SH.space2)
                .background(me ? SH.bgSunken : SH.bgRaised, in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous).strokeBorder(SH.border, lineWidth: 1))
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
            .shText(SH.appSmall).foregroundStyle(SH.textMuted)
        if !problem.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                SHIcon(.circleAlert).padding(.top, 1)
                Text(problem).shText(SH.appSmall)
            }
            .foregroundStyle(SH.danger)
            .accessibilityElement(children: .combine)
        }
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
