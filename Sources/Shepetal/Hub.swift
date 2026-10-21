import AppKit
import AVFoundation
import ShepetalCore
import SwiftUI

/// The one Shepetal window: Home, History, Dictionary, Meetings and Settings. It opens from the 🤫 menu and when the
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
         updater: SparkleUpdater? = nil, uninstallBlocker: @escaping () -> String? = { nil },
         openWhatsNew: @escaping () -> Void = {}, notices: @escaping () -> [NoticeLog.Notice] = { [] }) {
        model = HubModel(pipeline: pipeline, engine: engine, status: status, retention: retention,
                         setRetention: setRetention, openPermissions: openPermissions, loginItem: loginItem,
                         openDictionary: openDictionary, restoreFnKey: restoreFnKey, openWhatsNew: openWhatsNew,
                         notices: notices)
        model.updater = updater
        model.uninstallBlocker = uninstallBlocker
        meetings = MeetingsModel(store: meetingStore)
        dictionary = DictionaryModel(url: pipeline.dictionary, editAsText: openDictionary)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "shepetal"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HubView(model: model, meetings: meetings, dictionary: dictionary, input: input))
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
        let text = await finishText(e.rawText, bundleId: e.bundleId, url: e.url).text
        e.text = pressEnterCommand() ? PressEnter.split(text, raw: e.rawText).text : text
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
    var updater: SparkleUpdater?
    var uninstallBlocker: () -> String? = { nil }

    @Published var query = "" { didSet { reload() } }
    @Published var showArchived = false { didSet { reload() } }
    @Published private(set) var rows: [HistoryEntry] = []
    @Published private(set) var message = ""
    @Published private(set) var busy: String?  // id of the row being re-transcribed
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

    var automaticallyInstalls: Bool {
        get { updater?.automaticallyInstalls ?? false }
        set { updater?.automaticallyInstalls = newValue; objectWillChange.send() }
    }
}

private struct HubView: View {
    @ObservedObject var model: HubModel
    let meetings: MeetingsModel
    let dictionary: DictionaryModel
    let input: HubInput
    @AppStorage("hubTab") private var tab = "home"  // `-hubTab history` at launch picks one (screenshots)

    var body: some View {
        TabView(selection: $tab) {
            HomeTab(model: model).tabItem { Text("Home") }.tag("home")
            HistoryTab(model: model).tabItem { Text("History") }.tag("history")
            DictionaryTab(model: dictionary).tabItem { Text("Dictionary") }.tag("dictionary")
            MeetingsView(model: meetings).tabItem { Text("Meetings") }.tag("meetings")
            SettingsTab(model: model, meetings: meetings.store, input: input).tabItem { Text("Settings") }.tag("settings")
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
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
                    LabeledContent("fn problem") { Text(problem).foregroundStyle(.orange) }
                }
                LabeledContent("Permissions", value: missing.isEmpty ? "All granted"
                                                     : "Missing: " + missing.map(\.title).joined(separator: ", "))
                if !missing.isEmpty { Button("Open Permissions…", action: model.openPermissions) }
                StatsSection(history: model.pipeline.history)
                InsightsSection(history: model.pipeline.history)  // F61, F62: streak, heatmap, card
                Section("Recent notices") {
                    let notices = model.notices()
                    if notices.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(Array(notices.enumerated()), id: \.offset) { _, n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NoticeLog.time(n.time)).font(.caption).foregroundStyle(.secondary)
                            Text(n.text).textSelection(.enabled)
                        }
                    }
                }
                Section { Button("What's new…", action: model.openWhatsNew) }
                Section("Donate") {
                    ForEach(AppDelegate.donate, id: \.1) { title, url in Link(title, destination: URL(string: url)!) }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct HistoryTab: View {
    @ObservedObject var model: HubModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Search", text: $model.query).textFieldStyle(.roundedBorder)
                Toggle("Show archived", isOn: $model.showArchived)
            }
            List(model.rows, id: \.id) { e in row(e) }
            Text(model.message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ e: HistoryEntry) -> some View {
        let replay = e.canReplay()
        let header = [e.createdAt.formatted(date: .abbreviated, time: .shortened),
                      e.outcome.rawValue.replacingOccurrences(of: "_", with: " "),
                      e.app.isEmpty ? "unknown app" : e.app,
                      URL(string: e.url)?.host ?? "", e.archived ? "archived" : "", e.reverted ? "raw" : "",
                      replay ? "" : "recording deleted"].filter { !$0.isEmpty }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(header.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                Text(e.shownText.isEmpty ? "Nothing transcribed" : e.shownText).lineLimit(3).textSelection(.enabled)
            }
            Spacer()
            Button("Copy") { model.copy(e) }.disabled(e.shownText.isEmpty)
            Button(e.reverted ? "Show cleaned" : "Show raw") { model.setReverted(e, !e.reverted) }.disabled(e.text.isEmpty)
            Button("Play") { model.play(e) }.disabled(!replay)
            Menu("Re-transcribe") {
                ForEach(model.retryChoices, id: \.title) { c in Button(c.title) { model.retry(e, with: c.model) } }
            }
            .fixedSize()
            .disabled(!replay || model.busy != nil)
            Button(e.archived ? "Unarchive" : "Archive") { model.setArchived(e, !e.archived) }
        }
        .padding(.vertical, 2)
    }
}

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
    @AppStorage(MediaControl.muteKey) private var muteWhileDictating = false
    @AppStorage(MediaControl.pauseKey) private var pauseWhileDictating = false
    @AppStorage(PressEnter.key) private var pressEnterCommand = false
    @AppStorage(Streak.noticesKey) private var milestoneNotices = true
    @AppStorage(CleanupContext.settingKey) private var useTextAroundCursor = false

    var body: some View {
        Form {
            Toggle("Always record meetings automatically", isOn: $autoRecordMeetings)
            Text(autoRecordMeetings ? "A detected meeting records right away, with the red ring next to 🤫 the whole time."
                                    : "A detected meeting records only after you click Record next to 🤫.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Mute other audio while dictating", isOn: $muteWhileDictating)
            Toggle("Pause media while dictating", isOn: $pauseWhileDictating)
            Text("Only while another app is playing, and never during a meeting or a call. When you stop, shepetal turns the sound back on and resumes what it paused. Pause presses the play/pause key, so a video you paused just before dictating may start instead.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("End a dictation with “press enter” to press Return", isOn: $pressEnterCommand)
            Text("Return is pressed only after the text landed in the window you dictated into. Handy to send a chat message or a prompt.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Recordings", selection: Binding(get: model.retention, set: model.changeRetention)) {
                Text("Keep recordings").tag(Retention.keep)
                Text("Delete recordings after 24 hours").tag(Retention.delete24h)
            }
            Button("Open recordings folder") { NSWorkspace.shared.open(Paths.audio) }
            DataExportButton(history: model.pipeline.history, meetings: meetings)
            Toggle("Creator mode: show “\(Indicator.creatorLabel)” next to 🤫 while recording", isOn: $creatorMode)
            Text("For screen recordings and streams, so viewers see when you dictate.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Milestone notices", isOn: $milestoneNotices)
            Text("A short note next to 🤫 when a dictation reaches a streak or a word count, once each time.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Start at login", isOn: Binding(get: { model.loginItem.isOn }, set: { _ in model.toggleLogin() }))
            Toggle("Use the text around the cursor to clean up dictation", isOn: $useTextAroundCursor)
            Text("When the cleanup model rewrites a dictation, such as one with a correction or a list, it also gets up to 500 characters on each side of the cursor and up to 500 of the selection, on this Mac. It can fix the case of a name or go on with a numbered list, never add a word you did not say. Other dictations are not affected. The field's text is never saved or logged.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Dictionary…", action: model.openDictionary)
            HubInputSettings(input: input)
            AIAppsSettings()
            if FnKeySystem.enabled, let previous = FnKeySetting.restorable(FnKeySystem.io) {
                Button("Restore 🌐 key setting (\(FnKeySetting.describe(previous)))", action: model.restoreFnKey)
            }
            Button("Permissions…", action: model.openPermissions)
            StylesSection()  // F37
            AppFormatSection(history: model.pipeline.history)  // F33
            if model.updater != nil { Toggle("Install updates automatically", isOn: $model.automaticallyInstalls) }
            LabeledContent("Version", value: Self.version)
            UninstallSection(blocker: model.uninstallBlocker)  // last and quiet: never clicked by accident
        }
        .formStyle(.grouped)
    }
}
