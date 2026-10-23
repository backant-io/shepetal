import AppKit
import AVFoundation
import ShepetalCore
import SwiftUI

/// The one shepetal window: Home, History, Meetings, Settings and Dictionary. It opens from the 🤫 menu and when the
/// app is opened again while it runs. It opens by itself on Home only when dictation needs sign-in: once at launch,
/// and on a blocked fn press. Every setting is here; Shortcuts…, the mic and the languages are in the 🤫 menu too.
@MainActor
final class Hub {
    private let window: NSWindow
    private let model: HubModel
    private let meetings: MeetingsModel
    private let dictionary: DictionaryModel

    init(pipeline: Pipeline, engine: @escaping () -> SpeechEngine?,
         status: @escaping () -> (model: String, fnWatched: Bool),
         retention: @escaping () -> Retention, setRetention: @escaping (Retention) -> Void,
         openPermissions: @escaping () -> Void, loginItem: LoginItem, openDictionary: @escaping () -> Void,
         restoreFnKey: @escaping () -> Void, meetingStore: MeetingStoring = InMemoryMeetingStore(),
         input: HubInput = .none,
         uninstallBlocker: @escaping () -> String? = { nil },
         openWhatsNew: @escaping () -> Void = {}, notices: @escaping () -> [NoticeLog.Notice] = { [] }) {
        model = HubModel(pipeline: pipeline, engine: engine, status: status, retention: retention,
                         setRetention: setRetention, openPermissions: openPermissions, loginItem: loginItem,
                         openDictionary: openDictionary, restoreFnKey: restoreFnKey, openWhatsNew: openWhatsNew,
                         notices: notices)
        model.uninstallBlocker = uninstallBlocker
        meetings = MeetingsModel(store: meetingStore)
        dictionary = DictionaryModel(url: pipeline.dictionary, editAsText: openDictionary)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        // The unified title bar (design/ui/01-platforms.md): the content is drawn under it, and the bar the view
        // draws names the screen. The window keeps "shepetal" as its title (AccountWebLogin finds it by that).
        window.title = "shepetal"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "hub")  // empty: it only makes the bar tall enough to centre the traffic lights
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = SH.bg.nsColor
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HubView(model: model, meetings: meetings, dictionary: dictionary, input: input))
        // The view draws its own 40 pt bar under the title bar, so it takes no safe area from the window: a page's
        // scroll view then starts below that bar instead of reaching under the title bar.
        host.safeAreaRegions = []
        window.contentView = host
        window.center()
    }

    /// A re-transcribe in History is under way (an update waits for it).
    var retranscribing: Bool { model.busy != nil }

    func show() {
        model.reload()
        dictionary.reload()  // Edit as text… may have changed the file
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Home, with the account and Sign in at the top.
    func showHome() {
        UserDefaults.standard.set("home", forKey: "hubTab")
        show()
    }

    /// The Meetings tab (the 🤫 menu's Open Meetings, before there are any).
    func showMeetings() {
        UserDefaults.standard.set("meetings", forKey: "hubTab")
        show()
    }

    /// The Meetings tab with this meeting open (the transcript window's Open in Meetings).
    func showMeeting(_ id: String) {
        UserDefaults.standard.set("meetings", forKey: "hubTab")
        meetings.query = ""  // a search could hide it
        meetings.select(id)
        show()
    }
}

extension Pipeline {
    /// Re-transcribes a kept recording with `engine` through the same text step as dictation, and
    /// writes the new model, raw text and text to the same row. Its time, outcome and audio stay.
    func retranscribe(_ entry: HistoryEntry, with engine: SpeechEngine) async throws -> HistoryEntry {
        let wav = URL(fileURLWithPath: entry.audioPath)
        var e = entry
        let samples = try AudioStore.read(wav)
        e.rawText = try await engine.transcribe(await Task.detached { VoiceIsolation.apply(samples) }.value, wav: wav)
        // The row's app picks the format and the style (F33, F37); the command stays out of the text (F42).
        let finished = await finishText(e.rawText, bundleId: e.bundleId, url: e.url), text = finished.text
        e.text = pressEnterCommand() ? PressEnter.split(text, raw: e.rawText).text : text
        if finished.snippet == nil { e.text = await translate(e.text).text }  // F41; a snippet stays as stored (F40)
        e.model = engine.name
        try history.update(e)
        return e
    }
}

@MainActor
final class HubModel: ObservableObject {
    let pipeline: Pipeline
    let engine: () -> SpeechEngine?
    let status: () -> (model: String, fnWatched: Bool)
    let retention: () -> Retention
    let setRetention: (Retention) -> Void
    let openPermissions: () -> Void
    let loginItem: LoginItem
    let openDictionary: () -> Void
    let openWhatsNew: () -> Void  // the release notes (F111)
    let notices: () -> [NoticeLog.Notice]  // what 🤫 showed, newest first (F100)
    private let restore: () -> Void
    var uninstallBlocker: () -> String? = { nil }

    @Published var query = "" { didSet { reload() } }
    @Published var showArchived = false { didSet { reload() } }
    @Published private(set) var rows: [HistoryEntry] = []
    @Published private(set) var message = ""
    @Published private(set) var busy: String?  // id of the row being re-transcribed
    /// History's row tools show on hover and focus; screenshots, which have neither, show them on every row.
    @Published var showAllTools = false
    private var player: AVAudioPlayer?
    private var loaded: [SpeechModel: SpeechEngine] = [:]

    init(pipeline: Pipeline, engine: @escaping () -> SpeechEngine?, status: @escaping () -> (model: String, fnWatched: Bool),
         retention: @escaping () -> Retention, setRetention: @escaping (Retention) -> Void, openPermissions: @escaping () -> Void,
         loginItem: LoginItem, openDictionary: @escaping () -> Void, restoreFnKey: @escaping () -> Void,
         openWhatsNew: @escaping () -> Void, notices: @escaping () -> [NoticeLog.Notice]) {
        self.pipeline = pipeline; self.engine = engine; self.status = status
        self.retention = retention; self.setRetention = setRetention; self.openPermissions = openPermissions
        self.loginItem = loginItem; self.openDictionary = openDictionary; restore = restoreFnKey
        self.openWhatsNew = openWhatsNew; self.notices = notices
    }

    func reload() {
        do { rows = try pipeline.history.search(query, includeArchived: showArchived, limit: 200) } catch {
            message = "History: \(error.localizedDescription)"
        }
    }

    /// The model already running first, then the tier's other models (loaded on first use, never downloaded).
    var retryChoices: [(title: String, model: SpeechModel?)] {
        EngineLabel.retryChoices(current: engine()?.name)
    }

    func copy(_ e: HistoryEntry) {
        pipeline.copy(e.shownText)  // the pipeline's pasteboard: the clipboard in the app, a private one in tests
        message = "Copied"
    }

    func play(_ e: HistoryEntry) {
        do {
            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: e.audioPath))
            player?.play()
        } catch { message = "Play: \(error.localizedDescription)" }
    }

    func setArchived(_ e: HistoryEntry, _ archived: Bool) {
        do { try pipeline.history.setArchived(e.id, archived) } catch { message = "Archive: \(error.localizedDescription)" }
        reload()
    }

    /// Show raw / Show cleaned (F48): the row's Copy, and paste last and copy last, follow it.
    func setReverted(_ e: HistoryEntry, _ reverted: Bool) {
        do { try pipeline.history.setReverted(e.id, reverted) } catch { message = "Show raw: \(error.localizedDescription)" }
        reload()
    }

    func retry(_ e: HistoryEntry, with model: SpeechModel?) {
        busy = e.id
        message = "Re-transcribing…"
        Task {
            defer { busy = nil; reload() }
            do {
                let engine: SpeechEngine
                if let model {
                    if loaded[model] == nil { loaded[model] = try await Speech.engine(for: model) }
                    engine = loaded[model]!
                } else if let current = self.engine() {
                    engine = current
                } else {
                    throw SpeechError("Speech recognition is not loaded")
                }
                let done = try await pipeline.retranscribe(e, with: engine)
                message = "Re-transcribed with the \(EngineLabel.of(done.model)) engine"
            } catch {
                message = "Re-transcribe failed: " + (SpeechError(plain: error, "on-device speech recognition could not run").errorDescription ?? "")
            }
        }
    }

    func changeRetention(_ r: Retention) {
        setRetention(r)
        reload()
    }

    /// Both read macOS, not a published value, so Settings is told to draw again.
    func toggleLogin() {
        loginItem.toggle()
        objectWillChange.send()
    }

    func restoreFnKey() {
        restore()
        objectWillChange.send()
    }
}

/// The window's screens, in the sidebar's order and spelling (design/ui/components/Sidebar). The raw value is what
/// `hubTab` stores.
private enum HubScreen: String, CaseIterable {
    case home, history, meetings, settings, dictionary

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .meetings: "Meetings"
        case .settings: "Settings"
        case .dictionary: "Dictionary"
        }
    }

    var icon: SHIconName {
        switch self {
        case .home: .house
        case .history: .rotateCcwClock
        case .meetings: .users
        case .settings: .settings
        case .dictionary: .bookA
        }
    }
}

/// The title bar the view draws under the unified title bar, the 200 pt sidebar on the sunken ground, and the
/// screen beside it on sh-bg.
private struct HubView: View {
    @ObservedObject var model: HubModel
    let meetings: MeetingsModel
    let dictionary: DictionaryModel
    let input: HubInput
    @AppStorage("hubTab") private var tab = "home"  // `-hubTab history` at launch picks one (screenshots)

    private var screen: HubScreen { HubScreen(rawValue: tab) ?? .home }

    var body: some View {
        VStack(spacing: 0) {
            HubTitleBar(title: screen.title)
            HStack(spacing: 0) {
                SHSidebar {
                    ForEach(HubScreen.allCases, id: \.self) { s in
                        SHSidebarItem(s.title, icon: s.icon, current: s == screen) { tab = s.rawValue }
                    }
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(SH.bg)
        .foregroundStyle(SH.text)
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .home: HomeTab(model: model)
        case .history: HistoryTab(model: model)
        case .meetings: MeetingsView(model: meetings)
        case .settings: SettingsTab(model: model, meetings: meetings.store, input: input)
        case .dictionary:
            // .tabItem and .tag do nothing outside a TabView; HubTests reads this line for the tab's wiring.
            DictionaryTab(model: dictionary).tabItem { Text("Dictionary") }.tag("dictionary")
                .hubColumn()
        }
    }
}

/// The 40 pt bar at the top (design/ui/components/TitleBar): the screen's name centred in app-strong 13 over sh-bg,
/// a hairline below. The traffic lights are the window's own.
private struct HubTitleBar: View {
    let title: String

    var body: some View {
        Text(title)
            .shText(SH.appStrong.with(size: 13))
            .foregroundStyle(SH.text)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(SH.bg)
            .shHairline(.bottom)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The content column: 24 pt from the top, 32 from the sides and the bottom, at most 720 pt wide for reading.
    /// `fill` takes the window's height too; never inside a ScrollView, whose height has no end.
    fileprivate func hubColumn(fill: Bool = true) -> some View {
        padding(.top, SH.space5)
            .padding(.horizontal, SH.space6)
            .padding(.bottom, SH.space6)
            .frame(maxWidth: 720, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
    }
}

/// A screen that scrolls: its app-title, then its content, in the content column.
private struct HubPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SH.space5) {
                Text(title).shText(SH.appTitle).foregroundStyle(SH.text).accessibilityAddTraits(.isHeader)
                content
            }
            .hubColumn(fill: false)
        }
        .hubFlatTopEdge()
        .shText(SH.appBody)
        .foregroundStyle(SH.text)
        .background(SH.bg)
    }
}

extension View {
    /// The title bar is drawn on sh-bg with its hairline, so the page scrolls under a flat edge: no blur from the
    /// system's scroll edge effect (macOS 26), which is depth the system does not have.
    @ViewBuilder fileprivate func hubFlatTopEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

/// Home and Settings: a Form drawn as a page of rows instead of grouped boxes. Labeled content is a row, a toggle
/// names what is on with the switch on the right, and buttons are small keycaps.
private struct HubPageStyle: FormStyle {
    let title: String

    func makeBody(configuration: Configuration) -> some View {
        HubPage(title) {
            VStack(alignment: .leading, spacing: 0) { configuration.content }
                .shHairline(.top)
        }
        .labeledContentStyle(HubRowStyle())
        .toggleStyle(HubSwitchStyle())
        .buttonStyle(.keycap(.secondary, .sm))
    }
}

/// The spec row (design/ui/components/Row): the label in mono in the 104 pt column, the content, a hairline below.
private struct HubRow<Label: View, Content: View>: View {
    @ViewBuilder let label: Label
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.space5) {
            label
                .shText(SH.label)
                .foregroundStyle(SH.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: SH.rowLabel, alignment: .leading)
            VStack(alignment: .leading, spacing: SH.space1) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .shHairline(.bottom)
        .accessibilityElement(children: .contain)
    }
}

private struct HubRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HubRow { configuration.content } label: { configuration.label }
    }
}

/// A toggle in a row: what is on, named on the left, the switch on the right (design/ui/components/Toggle).
private struct HubSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HubSwitch(configuration: configuration)
    }
}

private struct HubSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(alignment: .center, spacing: SH.space5) {
            configuration.label
                .shText(SH.appStrong)
                .foregroundStyle(enabled ? SH.text : SH.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if enabled { configuration.$isOn.wrappedValue.toggle() } }
            Toggle(isOn: configuration.$isOn) { EmptyView() }.toggleStyle(.shSwitch)
        }
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// One line of help under a row's control, in app-small.
private struct HubHelp: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).shText(SH.appSmall).foregroundStyle(SH.textMuted).fixedSize(horizontal: false, vertical: true)
    }
}

/// A group of rows under its app-heading.
private struct HubSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).shText(SH.appHeading).foregroundStyle(SH.text).accessibilityAddTraits(.isHeader)
                .padding(.top, SH.space6)
                .padding(.bottom, SH.space2)
            VStack(alignment: .leading, spacing: 0) { content }.shHairline(.top)
        }
    }
}

private struct HomeTab: View {
    let model: HubModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let s = model.status()
            let missing = Permission.missing
            Form {
                AccountSection()
                LabeledContent("Speech recognition", value: s.model)
                LabeledContent("Cleanup", value: model.pipeline.cleanupStatus)
                LabeledContent("fn key", value: s.fnWatched ? "Watched: hold fn to talk, double-tap for hands-free"
                                                            : "Not watched yet (needs Input Monitoring)")
                if let problem = FnDiagnostics.problem {
                    LabeledContent("fn problem") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            SHIcon(.circleAlert).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                            Text(problem)
                        }
                        .foregroundStyle(SH.danger)
                    }
                }
                LabeledContent("Permissions") {
                    Text(missing.isEmpty ? "All granted" : "Missing: " + missing.map(\.title).joined(separator: ", "))
                    if !missing.isEmpty { Button("Open Permissions…", action: model.openPermissions).padding(.top, 6) }
                }
                StatsSection(history: model.pipeline.history)
                InsightsSection(history: model.pipeline.history)  // F61, F62: streak, heatmap, card
                ShareStatsSection(history: model.pipeline.history)  // F118
                HubSection("Recent notices") {
                    let notices = model.notices()
                    if notices.isEmpty {
                        Text("None yet").foregroundStyle(SH.textMuted).padding(.vertical, 14).shHairline(.bottom)
                    }
                    ForEach(Array(notices.enumerated()), id: \.offset) { _, n in
                        HubRow { Text(n.text).textSelection(.enabled) } label: { Text(NoticeLog.time(n.time)) }
                    }
                }
                Button("What's new…", action: model.openWhatsNew).padding(.top, SH.space5)
            }
            .formStyle(HubPageStyle(title: "Home"))
        }
    }
}

private struct HistoryTab: View {
    @ObservedObject var model: HubModel

    var body: some View {
        HubPage("History") {
            VStack(alignment: .leading, spacing: SH.space2) {
                HStack(alignment: .top, spacing: SH.space5) {
                    Text("Search").shText(SH.label).foregroundStyle(SH.textMuted)
                        .frame(width: SH.rowLabel, minHeight: SH.controlMd, alignment: .leading)
                        .accessibilityHidden(true)
                    // Show archived goes under the field when the column is too narrow for both.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: SH.space5) { search.frame(minWidth: 200); archived }
                        VStack(alignment: .leading, spacing: SH.space2) { search; archived }
                    }
                }
                if !model.message.isEmpty {
                    Text(model.message).shText(SH.appSmall).foregroundStyle(SH.textMuted)
                        .padding(.leading, SH.rowLabel + SH.space5)
                }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows, id: \.id) { e in Entry(model: model, e: e) }
            }
            .shHairline(.top)
        }
    }

    private var search: some View {
        TextField("e.g. invoice", text: $model.query).textFieldStyle(.shField).accessibilityLabel("Search")
    }

    private var archived: some View {
        Toggle("Show archived", isOn: $model.showArchived).toggleStyle(.shSwitch).fixedSize()
    }

    /// One dictation (design/ui/components/HistoryEntry): the app and the time in mono, the words as they landed,
    /// clamped at four lines with Show all, and quiet tools that show on hover and focus.
    private struct Entry: View {
        @ObservedObject var model: HubModel
        let e: HistoryEntry

        private enum Tool: Hashable { case copy, raw, play, retranscribe, archive }

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @FocusState private var focus: Tool?
        @State private var hover = false
        @State private var expanded = false
        @State private var width: CGFloat = 0

        var body: some View {
            let replay = e.canReplay()
            // Where it went and when; how it ended only when the text did not land as usual.
            let meta = [e.app.isEmpty ? "unknown app" : e.app,
                        e.createdAt.formatted(date: .omitted, time: .shortened),
                        e.createdAt.formatted(date: .abbreviated, time: .omitted),
                        e.outcome == .inserted ? "" : e.outcome.rawValue.replacingOccurrences(of: "_", with: " "),
                        URL(string: e.url)?.host ?? "", e.archived ? "archived" : "", e.reverted ? "raw" : "",
                        replay ? "" : "recording deleted"].filter { !$0.isEmpty }
            let tools = hover || focus != nil || model.showAllTools
            HStack(alignment: .top, spacing: SH.space5) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(meta.indices, id: \.self) { i in
                        Text(meta[i]).shText(SH.label).foregroundStyle(SH.textMuted)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
                .frame(width: SH.rowLabel, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.shownText.isEmpty ? "Nothing transcribed" : e.shownText)
                        .shText(SH.appBody)
                        .foregroundStyle(e.shownText.isEmpty ? SH.textMuted : SH.text)
                        .lineLimit(expanded ? nil : 4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    if !expanded, Self.lines(e.shownText, width: width) > 4 {
                        Button("Show all") { expanded = true }.buttonStyle(.keycap(.quiet, .sm)).padding(.top, 6)
                    }
                    HStack(spacing: SH.space1) {
                        Button { model.copy(e) } label: { Label { Text("Copy text") } icon: { SHIcon(.copy) } }
                            .focused($focus, equals: .copy)
                            .disabled(e.shownText.isEmpty)
                        Button(e.reverted ? "Show cleaned" : "Show raw") { model.setReverted(e, !e.reverted) }
                            .focused($focus, equals: .raw)
                            .disabled(e.text.isEmpty)
                        Button("Play") { model.play(e) }.focused($focus, equals: .play).disabled(!replay)
                        Menu {
                            ForEach(model.retryChoices, id: \.title) { c in Button(c.title) { model.retry(e, with: c.model) } }
                        } label: {
                            Label { Text("Re-transcribe") } icon: { SHIcon(.rotateCcwClock) }
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .focused($focus, equals: .retranscribe)
                        .disabled(!replay || model.busy != nil)
                        Button(e.archived ? "Unarchive" : "Archive") { model.setArchived(e, !e.archived) }
                            .focused($focus, equals: .archive)
                    }
                    .buttonStyle(.keycap(.quiet, .sm))
                    .fixedSize()
                    // Folded away until hover or focus, but still in the key view loop, so Tab reaches and opens them.
                    .padding(.top, tools ? 6 : 0)
                    .frame(maxHeight: tools ? nil : 0, alignment: .top)
                    .clipped()
                    .opacity(tools ? 1 : 0)
                    .animation(SH.settle(reduce: reduceMotion), value: tools)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .shHairline(.bottom)
            .onHover { hover = $0 }
        }

        /// How many lines `text` takes in app-body at `width`.
        private static func lines(_ text: String, width: CGFloat) -> Int {
            guard width > 0, !text.isEmpty else { return 0 }
            let font = SH.appBody.nsFont
            let height = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                         attributes: [.font: font]).height
            return Int((height / NSLayoutManager().defaultLineHeight(for: font)).rounded())
        }
    }
}

/// Every setting as a row, in the order they had; the sections from other files keep their own layout inside it.
private struct SettingsTab: View {
    @ObservedObject var model: HubModel
    let meetings: MeetingStoring
    let input: HubInput
    static let version: String = {
        let i = Bundle.main.infoDictionary ?? [:]
        return "\(i["CFBundleShortVersionString"] as? String ?? "dev") (\(i["CFBundleVersion"] as? String ?? "0"))"
    }()
    @AppStorage(MeetingRecorder.autoRecordKey) private var autoRecordMeetings = false
    @AppStorage(Indicator.creatorModeKey) private var creatorMode = false
    @AppStorage(LiveText.key) private var liveText = LiveText.defaultOn
    @AppStorage(MediaControl.muteKey) private var muteWhileDictating = false
    @AppStorage(MediaControl.pauseKey) private var pauseWhileDictating = false
    @AppStorage(PressEnter.key) private var pressEnterCommand = false
    @AppStorage(Streak.noticesKey) private var milestoneNotices = true
    @AppStorage(CleanupContext.settingKey) private var useTextAroundCursor = true

    var body: some View {
        Form {
            LabeledContent("Meetings") {
                Toggle("Always record meetings automatically", isOn: $autoRecordMeetings)
                HubHelp(autoRecordMeetings ? "A detected meeting records right away, with the recording ring on the indicator the whole time."
                                           : "A detected meeting records only after you click Record in the meeting reminder.")
            }
            LabeledContent("Media") {
                Toggle("Mute other audio while dictating", isOn: $muteWhileDictating)
                Toggle("Pause media while dictating", isOn: $pauseWhileDictating)
                HubHelp("Only while another app is playing, and never during a meeting or a call. When you stop, shepetal turns the sound back on and resumes what it paused. Pause presses the play/pause key, so a video you paused just before dictating can start instead.")
            }
            LabeledContent("Return") {
                Toggle("End a dictation with “press enter” to press Return", isOn: $pressEnterCommand)
                HubHelp("Return is pressed only after the text landed in the window you dictated into. Handy to send a chat message or a prompt.")
            }
            LabeledContent("Recordings") {
                Picker("Recordings", selection: Binding(get: model.retention, set: model.changeRetention)) {
                    Text("Keep recordings").tag(Retention.keep)
                    Text("Delete recordings after 24 hours").tag(Retention.delete24h)
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent("Transcripts") { TranscriptRetentionPicker(store: meetings) }  // F81
            LabeledContent("Folder") { Button("Open recordings folder") { NSWorkspace.shared.open(Paths.audio) } }
            LabeledContent("Export") { DataExportButton(history: model.pipeline.history, meetings: meetings) }
            LabeledContent("Indicator") {
                Toggle("Creator mode: show “\(Indicator.creatorLabel)” next to the indicator while recording", isOn: $creatorMode)
                HubHelp("For screen recordings and streams, so viewers see when you dictate.")
            }
            LabeledContent("Live text") {
                Toggle("Show words while you speak", isOn: $liveText)
                HubHelp("Your last words show next to the indicator while you dictate. Only the final text is pasted, into the window you dictated into. Not with the alternative engine.")
            }
            LabeledContent("Notices") {
                Toggle("Milestone notices", isOn: $milestoneNotices)
                HubHelp("A short note next to the indicator when a dictation reaches a streak or a word count, once each time.")
            }
            LabeledContent("Login") {
                Toggle("Start at login", isOn: Binding(get: { model.loginItem.isOn }, set: { _ in model.toggleLogin() }))
            }
            LabeledContent("Context") {
                Toggle("Use the text around the cursor to clean up dictation", isOn: $useTextAroundCursor)
                HubHelp("When the cleanup model rewrites a dictation, such as one with a correction or a list, it also gets at most 500 characters on each side of the cursor and at most 500 of the selection, on this Mac. It can fix the case of a name or go on with a numbered list, never add a word you did not say. Other dictations are not affected. The field's text is never saved or logged.")
            }
            LabeledContent("Words") { words }
            HubInputSettings(input: input)
            AIAppsSettings()
            if FnKeySystem.enabled, let previous = FnKeySetting.restorable(FnKeySystem.io) {
                LabeledContent("Globe key") {
                    Button("Restore 🌐 key setting (\(FnKeySetting.describe(previous)))", action: model.restoreFnKey)
                }
            }
            LabeledContent("Permissions") { Button("Permissions…", action: model.openPermissions) }
            StylesSection()  // F37
            MyVoiceSection(url: model.pipeline.voiceFile, cleanup: { [weak model] in model?.pipeline.cleanup })  // F38
            EmailSection()  // F36: the signature
            AppFormatSection(history: model.pipeline.history)  // F33
            LabeledContent("Version", value: Self.version)
            UninstallSection(blocker: model.uninstallBlocker)  // last and quiet: never clicked by accident
        }
        .formStyle(HubPageStyle(title: "Settings"))
    }

    /// The word lists, side by side.
    private var words: some View {
        HStack(spacing: SH.space2) {
            Button("Dictionary…", action: model.openDictionary)
            Button("Snippets…") { SnippetsFile.open(model.pipeline.snippets) }  // F40
        }
    }
}
