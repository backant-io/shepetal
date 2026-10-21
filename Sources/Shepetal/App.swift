import AppKit
import ShepetalCore

/// The menu-bar app: fn gestures drive the recorder, the pipeline inserts the text, the indicator shows state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let allowPrompts: Bool
    private let hintAtLaunch: Bool
    private var statusItem: NSStatusItem!
    private var indicator: Indicator!
    private let tap = FnTap()
    private let mic = Mic()
    private let speech = SpeechMenu()
    private var dictation: Dictation?
    private var pipeline: Pipeline?
    private var engine: SpeechEngine?
    private var engineStatus = "Loading on-device speech recognition…"
    private var cleanupStatus = "Cleanup: loading…"
    private var downloadingCleanup = false
    private var busy = false { didSet { syncTap() } }
    private var pasting = false  // paste last is under way
    private var tick: DispatchWorkItem?
    private var onboarding: Onboarding?
    private var shortcuts: ShortcutsWindow?
    private var transcription: Task<Void, Never>?
    private var inserting = false { didSet { syncTap() } }  // the paste is under way, too late for Esc
    private var timers: [Timer] = []
    private var focusAtStart: (app: Int32, window: AXUIElement?)?
    private lazy var secureInput = SecureInput(indicator: indicator)
    private var permissions: PermissionMonitor!
    private let fnWatch = FnWatch()
    private var tapFailed = false
    private lazy var loginItem = LoginItem { [weak self] in self?.indicator.show($0, seconds: 6) }
    private var hub: Hub?
    private var appAtStart: Task<AppContext, Never>?
    private var meetingFlow: MeetingFlow?
    private var transcriptWindow: MeetingTranscriptWindow?
    private lazy var meetings: MeetingRecorder = MeetingRecorder(capture: SystemMeetingCapture(allowPrompts: allowPrompts),
                                                                 card: { [weak self] in self?.meetingCard.show($0) }) { [weak self] in self?.indicator.show($0, seconds: 4) }
    /// "Meeting detected · <app>": nothing records until Record is clicked (unless the setting says always).
    private lazy var meetingCard: MeetingCard = MeetingCard(onRecord: { [weak self] in self?.meetings.record() },
                                                            onNotNow: { [weak self] in self?.meetings.notNow() })

    static let donate = [("Buy Me a Coffee", "https://buymeacoffee.com/sorcecoder"),
                         ("GitHub Sponsors", "https://github.com/sponsors/backant-io")]

    init(allowPrompts: Bool, hintAtLaunch: Bool) {
        self.allowPrompts = allowPrompts
        self.hintAtLaunch = hintAtLaunch
    }

    private var retention: Retention {
        get { Retention(rawValue: UserDefaults.standard.string(forKey: "retention") ?? "") ?? .keep }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "retention"); applyRetention() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        indicator = Indicator()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🤫"
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        do { pipeline = try Pipeline(pasteboard: .general) } catch { fail("Storage: \(error.localizedDescription)") }
        if let pipeline {
            dictation = Dictation(store: pipeline.store, history: pipeline.history,
                                  startMic: { [weak self] in try self?.openMic() },
                                  stopMic: { [mic] in mic.stop() },
                                  transcribe: { [weak self] in self?.transcribe($0) })
        }
        let minutes = UserDefaults.standard.integer(forKey: "maxDictationMinutes")
        if minutes > 0 { dictation?.gesture.maxDuration = TimeInterval(minutes * 60) }
        tap.updateRouter { $0.shortcuts = ShortcutsWindow.saved }
        // Off the tap callback: opening the mic is slow, and a slow callback gets the tap turned off.
        tap.onInput = { [weak self] input, t in DispatchQueue.main.async { MainActor.assumeIsolated { self?.key(input, at: t) } } }
        wireMicAndSpeech()
        fnWatch.onUnreported = { [weak self] in self?.fnProblem(FnHealth.hint) }
        fnWatch.active = { [weak self] in self?.tap.isRunning == true }
        fnWatch.start()
        startTapIfAllowed()
        // Retention runs hourly; the tap starts as soon as Input Monitoring is granted.
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTapIfAllowed(); self?.secureInput.check(); self?.permissions.check() }
        })
        Task { await loadEngine() }
        Task { await loadCleanup() }
        do {  // recorder → transcriber → meetings.sqlite → summary; the Meetings tab reads the same store
            meetingFlow = try MeetingFlow.onDisk(engine: { [weak self] in self?.engine }) { [weak self] in self?.indicator.show($0, seconds: 4) }
            meetingFlow?.attach(meetings)
            meetingFlow?.onRecording = { [weak self] in
                self?.statusItem.button?.title = $0 ? "🤫●" : "🤫"
                self?.indicator.meeting = $0  // the red ring, for the whole recording
            }
            meetingFlow?.onTranscript = { [weak self] in self?.showTranscript($0) }
        } catch { fail("Meetings: \(error.localizedDescription)") }
        meetings.watch()
        applyRetention()

        // Before the permission check, so a missing-permission message replaces the account hint, not the reverse.
        Account.shared.start(isDictating: { [weak self] in self?.busy == true || (self?.dictation?.gesture.state ?? .idle) != .idle },
                             hint: { [weak self] in self?.indicator.show($0, seconds: 6) })
        permissions = PermissionMonitor(revoked: { [weak self] message in
            self?.fail(message)
            if self?.allowPrompts == true { self?.showOnboarding() }
        }, restored: { [weak self] in
            if self?.indicator.mode == .error { self?.indicator.set(.idle) }
        })
        if !Permission.missing.isEmpty {
            if allowPrompts { showOnboarding() } else { fail("Needs \(Permission.missing.map(\.title).joined(separator: ", "))") }
        }
        if hintAtLaunch { indicator.show(holdHint, seconds: Hint.seconds) }
        if CommandLine.arguments.contains("--show-shortcuts") { openShortcuts() }
        applyFnKeySetting()
    }

    /// "Press 🌐 key to" must be Do Nothing, or fn switches the input source instead of dictating.
    /// Checked at every launch; says something only when it changed the setting or could not.
    private func applyFnKeySetting() {
        guard FnKeySystem.enabled, allowPrompts else { return }  // never from --no-permission-prompts test launches
        let outcome = FnKeySetting.apply(FnKeySystem.io)
        switch outcome {
        case .alreadySet: break
        case .changed, .changedByInstaller: indicator.show(FnKeySetting.changedHint, seconds: 6)
        case .failed: fnProblem(FnKeySetting.failedHint)
        }
    }

    /// The tap delivered fn: an earlier "fn not received" no longer holds.
    private func fnReceived() {
        fnWatch.tapEvent()
        guard FnDiagnostics.problem == FnHealth.hint else { return }
        FnDiagnostics.problem = nil
        if indicator.mode == .error { indicator.set(.idle) }
    }

    private func fnProblem(_ message: String) {
        FnDiagnostics.problem = message
        indicator.set(.error)
        indicator.show(message, seconds: 8)
    }

    /// Closes the meeting files so their WAV headers are written (rule 4).
    func applicationWillTerminate(_ notification: Notification) { meetings.stop() }

    // MARK: keys → gestures

    /// `t`: when the key moved (`FnClock`), which can be well before the main thread reads it.
    private func key(_ input: KeyInput, at t: TimeInterval) {
        let idle = dictation?.gesture.state == .idle
        if [.pttDown, .pttUp, .toggle].contains(input) { fnReceived() }
        switch input {
        case .pasteLast: pasteLast()
        case .copyLast: copyLast()
        case .recorded(let chord): shortcuts?.recorded(chord)
        case .dismiss where idle:
            // Esc while transcribing: Pipeline inserts nothing and keeps the row as cancelled.
            guard let transcription, !inserting else { return }
            transcription.cancel()
            indicator.show(Hint.cancelled, seconds: Hint.seconds)
        case .pttDown where (busy || pasting) && idle, .toggle where (busy || pasting) && idle:
            indicator.show("Still transcribing the last one", seconds: Hint.seconds)
        case .pttDown where idle && !Account.shared.allowFnDown(), .toggle where idle && !Account.shared.allowFnDown():
            return  // signed out or trial over
        default:
            run { $0.handle(input, at: t) }
            if input == .dismiss { indicator.show(Hint.cancelled, seconds: Hint.seconds) }
        }
    }

    /// One fn event through the session (mic, kept audio, transcription), then the indicator.
    private func run(_ event: (inout FnGesture) -> [GestureAction]) {
        guard let dictation else { return }
        do {
            for action in try dictation.run(event) { show(action) }
        } catch {
            fail(error.localizedDescription)
        }
        syncTap()
        scheduleTick()
    }

    /// What the tap's thread reads to decide whether Esc is ours: a dictation, or a transcription before its paste.
    private func syncTap() { tap.isActive = (busy && !inserting) || (dictation?.gesture.state ?? .idle) != .idle }

    /// The short-press hint and the menu's first line, named after the hold-to-talk chord.
    private var holdHint: String { Hint.holdToTalk(Key.label(tap.router.shortcuts.chord(.ptt))) }

    private func scheduleTick() {
        tick?.cancel()
        guard let deadline = dictation?.gesture.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.run { $0.tick(at: ProcessInfo.processInfo.systemUptime) } }
        }
        tick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    private func show(_ action: GestureAction) {
        switch action {
        case .start:
            focusAtStart = FocusedText.window()
            indicator.set(.recording)
            appAtStart = AppContext.capture()
        case .lockHandsFree: indicator.set(.handsFree)
        case .tooShort:
            indicator.set(.idle)
            indicator.show(holdHint, seconds: Hint.seconds)
        case .cancel: indicator.set(.idle)
        case .warnDuration: indicator.show(Hint.oneMinuteLeft, seconds: 5)
        case .stop: break  // transcribe(_:) shows processing
        }
    }

    private func openMic() throws {
        guard Recorder.micAllowed else {
            if allowPrompts { Permission.microphone.request() }
            throw SpeechError("Microphone access is off")
        }
        do { try mic.open() } catch { throw SpeechError("Microphone: \(error.localizedDescription)") }
    }

    /// Mic problems end the dictation through the gesture, so the audio is kept like any other recording.
    private func wireMicAndSpeech() {
        mic.notice = { [weak self] in self?.indicator.show($0, seconds: 4) }
        mic.end = { [weak self] transcribe, message in
            self?.run { $0.reset(); return [transcribe ? .stop : .cancel] }
            self?.fail(message)
        }
        speech.reload = { [weak self] in
            self?.engineStatus = "Loading on-device speech recognition…"
            Task { await self?.loadEngine() }
        }
        speech.fail = { [weak self] in self?.fail($0) }
        mic.watch()
    }

    private func transcribe(_ samples: [Float]) {
        guard let pipeline else { return }
        busy = true
        indicator.set(.processing)
        let appAtStart = appAtStart
        let start = focusAtStart
        transcription = Task {
            let app = await appAtStart?.value ?? AppContext()
            var shown: String?
            // Pipeline reads the context right after its last cancel check; a cancel during the paste
            // would cut the paste's waits short.
            let run = await pipeline.process(samples, engine: engine, app: app, context: { [weak self] in
                self?.inserting = true
                return FocusedText.context()
            }, focusKept: { PasteGate.focusKept(start: start, now: FocusedText.window()) },
               secureInput: SecureInput.blocker, sendPaste: Inserter.postCmdV,
               decided: { [weak self] in shown = $0; self?.finish($0) })
            busy = false
            inserting = false
            transcription = nil
            if run.error != shown { finish(run.error) }  // the WAV or the history row failed afterwards
            if !Task.isCancelled, Mic.isQuiet(samples), run.error == nil || run.entry.text.isEmpty { indicator.show(MicHealth.quietHint, seconds: 4) }
        }
    }

    /// Paste last / copy last: the newest history text, a paste that did not land included.
    private func lastHistoryText() -> String? {
        let text = lastText(in: (try? pipeline?.history.recent(limit: 50)) ?? [])
        if text == nil { indicator.show(Hint.nothingToPaste, seconds: Hint.seconds) }
        return text
    }

    /// Only between dictations, one at a time, and through the same gate as dictation: under secure input the
    /// text goes to the clipboard instead (rule 8).
    private func pasteLast() {
        guard let pipeline, !busy, !pasting, dictation?.gesture.state == .idle, let text = lastHistoryText() else { return }
        if let app = SecureInput.blocker() {
            pipeline.inserter.leaveOnClipboard(text)
            return fail(PasteGate.secureInput(app))
        }
        pasting = true
        Task {
            let paste = await pipeline.inserter.insert(text, sendPaste: Inserter.postCmdV)
            pasting = false
            if !paste.landed { fail(PasteGate.notLanded) }
        }
    }

    private func copyLast() {
        guard let text = lastHistoryText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        indicator.show("Copied", seconds: 1.5)
    }

    /// The end of a dictation. Esc while transcribing (#47) shows no error.
    private func finish(_ error: String?) {
        if let error, !Task.isCancelled { fail(error) } else { indicator.set(.idle) }
    }

    private func fail(_ message: String) {
        indicator.set(.error)
        indicator.show(message, seconds: 4)
    }

    // MARK: setup

    private func loadEngine() async {
        do {
            let e = try await Speech.load(languages: speech.languages)
            engine = e
            engineStatus = EngineLabel.status(e.name)
        } catch {
            engine = nil
            NSLog("shepetal: speech: %@", error.localizedDescription)  // model names stay in the log
            let tier = currentModelTier()
            engineStatus = speechRoute(languages: speech.languages, tier: tier).model != tier.primary
                ? error.localizedDescription  // Speech.load's own plain message names the languages
                : ParakeetEngine.isInstalled ? "On-device speech recognition could not start"
                                             : "On-device speech recognition is not downloaded yet"
            fail("No speech recognition. Open the 🤫 menu.")
        }
    }

    private func loadCleanup() async {
        cleanupStatus = await pipeline?.loadCleanup() ?? "Cleanup: rules only"
    }

    private func startTapIfAllowed() {
        // listen-only → active once Accessibility is granted, and back when it is revoked
        if tap.isRunning, tap.canSwallow != Permission.accessibility.granted { tap.stop() }
        guard !tap.isRunning, Permission.inputMonitoring.granted else { return }
        if tap.start() {
            tapFailed = false
            if FnDiagnostics.problem == FnHealth.hint { FnDiagnostics.problem = nil }
            if indicator.mode == .error, Permission.missing.isEmpty { indicator.set(.idle) }
        } else if !tapFailed {
            tapFailed = true  // granted, yet macOS refuses the tap: the grant belongs to another build
            fnProblem(FnHealth.hint)
        }
    }

    private func applyRetention() {
        do { try pipeline?.store.applyRetention(retention) } catch { fail("Retention: \(error.localizedDescription)") }
        // Meeting audio follows the same choice; the meeting being recorded is never deleted.
        do { try meetingFlow?.store.applyRetention(retention, dir: meetings.dir, recording: meetings.current?.id) }
        catch { fail("Meeting retention: \(error.localizedDescription)") }
    }

    private func showOnboarding() {
        onboarding = onboarding ?? Onboarding(allowRequests: allowPrompts)
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.window?.center()
        onboarding?.showWindow(nil)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: tap.isRunning ? holdHint : "fn is not being watched yet", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: engineStatus, action: nil, keyEquivalent: "")
        menu.addItem(item("Open Shepetal…", #selector(openHub)))
        Account.shared.menuItems().forEach(menu.addItem)
        if engine == nil, !ParakeetEngine.isInstalled {
            menu.addItem(item("Download on-device speech recognition (about 470 MB)", #selector(downloadModel)))
        }
        menu.addItem(withTitle: cleanupStatus, action: nil, keyEquivalent: "")
        if pipeline?.cleanup == nil, !downloadingCleanup, let m = currentCleanupModel(),
           !FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent(m.file).path) {
            menu.addItem(item("Download cleanup model (about \(String(format: "%.1f", Double(m.megabytes) / 1000)) GB)",
                              #selector(downloadCleanup)))
        }
        for i in [mic.menuItem()] + speech.items() { menu.addItem(i) }
        menu.addItem(.separator())

        let recent = NSMenu()
        for entry in (try? pipeline?.history.recent(limit: 10)) ?? [] {
            let title = entry.text.isEmpty ? "(\(entry.outcome.rawValue.replacingOccurrences(of: "_", with: " ")))" : String(entry.text.prefix(60))
            let i = item(title, #selector(copyEntry(_:)))
            i.representedObject = entry.text
            i.isEnabled = !entry.text.isEmpty
            recent.addItem(i)
        }
        if recent.items.isEmpty { recent.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "") }
        let recentItem = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        let keys = tap.router.shortcuts
        menu.addItem(item("Paste last text (\(Key.label(keys.chord(.pasteLast))))", #selector(menuPasteLast)))
        menu.addItem(item("Copy last text (\(Key.label(keys.chord(.copyLast))))", #selector(menuCopyLast)))
        menu.addItem(item("Shortcuts…", #selector(openShortcuts)))

        let keep = NSMenu()
        for (r, title) in [(Retention.keep, "Keep recordings"), (.delete24h, "Delete recordings after 24 hours")] {
            let i = item(title, #selector(setRetention(_:)))
            i.representedObject = r.rawValue
            i.state = retention == r ? .on : .off
            keep.addItem(i)
        }
        let keepItem = NSMenuItem(title: "Recordings", action: nil, keyEquivalent: "")
        keepItem.submenu = keep
        menu.addItem(keepItem)
        menu.addItem(item("Open recordings folder", #selector(openRecordings)))
        menu.addItem(meetings.menuItem)
        menu.addItem(loginItem.menuItem)
        if FnKeySystem.enabled, let previous = FnKeySetting.restorable(FnKeySystem.io) {
            menu.addItem(item("Restore 🌐 key setting (\(FnKeySetting.describe(previous)))", #selector(restoreFnKey)))
        }
        menu.addItem(item(Permission.missing.isEmpty ? "Permissions…" : "Permissions… (\(Permission.missing.count) missing)", #selector(openPermissions)))
        menu.addItem(.separator())
        for (title, url) in Self.donate {
            let i = item("Donate: \(title)", #selector(openLink(_:)))
            i.representedObject = url
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Shepetal", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = target ?? self
        return i
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.representedObject as? String ?? "", forType: .string)
    }

    @objc private func setRetention(_ sender: NSMenuItem) {
        retention = Retention(rawValue: sender.representedObject as? String ?? "") ?? .keep
    }

    @objc private func menuPasteLast() { pasteLast() }
    @objc private func menuCopyLast() { copyLast() }

    @objc private func openShortcuts() {
        shortcuts = shortcuts ?? ShortcutsWindow(tap: tap)
        NSApp.activate(ignoringOtherApps: true)
        shortcuts?.window?.center()
        shortcuts?.showWindow(nil)
    }

    /// Opening the app again while it runs (Finder, Spotlight, `open`) shows the hub.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHub()
        return false
    }

    @objc private func openHub() { openedHub()?.show() }

    /// The meeting's transcript window, in front without taking focus from the app in use.
    private func showTranscript(_ m: Meeting) {
        guard let store = meetingFlow?.store else { return }
        transcriptWindow = transcriptWindow ?? MeetingTranscriptWindow(model: MeetingsModel(store: store)) { [weak self] in
            self?.openedHub()?.showMeeting($0)
        }
        transcriptWindow?.show(m)
    }

    private func openedHub() -> Hub? {
        guard let pipeline else { fail("History is not available"); return nil }
        hub = hub ?? Hub(pipeline: pipeline, engine: { [weak self] in self?.engine },
                         status: { [weak self] in (self?.engineStatus ?? "", self?.tap.isRunning == true) },
                         retention: { [weak self] in self?.retention ?? .keep },
                         setRetention: { [weak self] in self?.retention = $0 },
                         openPermissions: { [weak self] in self?.showOnboarding() },
                         meetingStore: meetingFlow?.store ?? InMemoryMeetingStore())
        return hub
    }

    @objc private func restoreFnKey() {
        let previous = FnKeySetting.restorable(FnKeySystem.io)
        guard FnKeySetting.restore(FnKeySystem.io) else { return }
        indicator.show("🌐 key back to \(FnKeySetting.describe(previous)) until Shepetal starts again", seconds: 6)
    }

    @objc private func openRecordings() { NSWorkspace.shared.open(Paths.audio) }
    @objc private func openPermissions() { showOnboarding() }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// The menu hides the download item while this runs, so a second click cannot start a second download.
    @objc private func downloadCleanup() {
        guard !downloadingCleanup else { return }
        downloadingCleanup = true
        cleanupStatus = "Downloading the cleanup model…"
        Task {
            defer { downloadingCleanup = false }
            do { try await Pipeline.downloadCleanup() } catch {
                FileHandle.standardError.write(Data("cleanup model download: \(error)\n".utf8))
                cleanupStatus = "Cleanup model download failed. Try again later."
                return
            }
            await loadCleanup()
        }
    }

    @objc private func downloadModel() {
        engineStatus = "Downloading on-device speech recognition…"
        Task {
            do { try await ParakeetEngine.download() } catch { engineStatus = "Download failed: " + (SpeechError(plain: error, "check the internet connection and try again").errorDescription ?? ""); return }
            await loadEngine()
        }
    }
}
