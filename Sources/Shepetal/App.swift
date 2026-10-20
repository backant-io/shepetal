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
    private let recorder = Recorder()
    private var dictation: Dictation?
    private var pipeline: Pipeline?
    private var engine: SpeechEngine?
    private var engineStatus = "Loading on-device speech recognition…"
    private var busy = false
    private var tick: DispatchWorkItem?
    private var onboarding: Onboarding?
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
                                  stopMic: { [recorder] in recorder.stop() },
                                  transcribe: { [weak self] in self?.transcribe($0) })
        }
        applyRetention()
        tap.onChange = { [weak self] down, t in self?.fnWatch.tapEvent(); self?.fn(down, at: t) }
        fnWatch.onUnreported = { [weak self] in self?.fnProblem(FnHealth.hint) }
        fnWatch.start()
        tap.onOtherKey = { [weak self] t in self?.run { $0.otherKeyDown(at: t) } }
        recorder.onError = { [weak self] in self?.fail($0) }
        startTapIfAllowed()
        // Retention runs hourly; the tap starts as soon as Input Monitoring is granted.
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTapIfAllowed(); self?.secureInput.check(); self?.permissions.check() }
        })
        Task { await loadEngine() }
        do {  // recorder → transcriber → meetings.sqlite → summary; the Meetings tab reads the same store
            meetingFlow = try MeetingFlow.onDisk(engine: { [weak self] in self?.engine }) { [weak self] in self?.indicator.show($0, seconds: 4) }
            meetingFlow?.attach(meetings)
            meetingFlow?.onRecording = { [weak self] in
                self?.statusItem.button?.title = $0 ? "🤫●" : "🤫"
                self?.indicator.meeting = $0  // the red ring, for the whole recording
            }
        } catch { fail("Meetings: \(error.localizedDescription)") }
        meetings.watch()

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
        if hintAtLaunch { indicator.show(Hint.shortPress, seconds: Hint.seconds) }
        applyFnKeySetting()
    }

    /// "Press 🌐 key to" must be Do Nothing, or fn switches the input source instead of dictating.
    /// Checked at every launch; says something only when it changed the setting or could not.
    private func applyFnKeySetting() {
        guard FnKeySystem.enabled else { return }
        let outcome = FnKeySetting.apply(FnKeySystem.io)
        switch outcome {
        case .alreadySet: break
        case .changed: indicator.show(FnKeySetting.changedHint, seconds: 6)
        case .failed: fnProblem(FnKeySetting.failedHint)
        }
    }

    private func fnProblem(_ message: String) {
        FnDiagnostics.problem = message
        indicator.set(.error)
        indicator.show(message, seconds: 8)
    }

    /// Closes the meeting files so their WAV headers are written (rule 4).
    func applicationWillTerminate(_ notification: Notification) { meetings.stop() }

    // MARK: fn → gestures

    private func fn(_ down: Bool, at t: TimeInterval) {
        if down, busy, dictation?.gesture.state == .idle {
            indicator.show("Still transcribing the last one", seconds: Hint.seconds)
            return
        }
        if down, dictation?.gesture.state == .idle, !Account.shared.allowFnDown() { return }  // signed out or trial over
        run { down ? $0.fnDown(at: t) : $0.fnUp(at: t) }
    }

    /// One fn event through the session (mic, kept audio, transcription), then the indicator.
    private func run(_ event: (inout FnGesture) -> [GestureAction]) {
        guard let dictation else { return }
        do {
            for action in try dictation.run(event) { show(action) }
        } catch {
            fail(error.localizedDescription)
        }
        scheduleTick()
    }

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
            indicator.show(Hint.shortPress, seconds: Hint.seconds)
        case .cancel: indicator.set(.idle)
        case .stop: break  // transcribe(_:) shows processing
        }
    }

    private func openMic() throws {
        guard Recorder.micAllowed else {
            if allowPrompts { Permission.microphone.request() }
            throw SpeechError("Microphone access is off")
        }
        recorder.start()
    }

    private func transcribe(_ samples: [Float]) {
        guard let pipeline else { return }
        busy = true
        indicator.set(.processing)
        let appAtStart = appAtStart
        let start = focusAtStart
        Task {
            let app = await appAtStart?.value ?? AppContext()
            let run = await pipeline.process(samples, engine: engine, app: app, context: FocusedText.context,
                                             selection: FocusedText.selected,
                                             focusKept: { PasteGate.focusKept(start: start, now: FocusedText.window()) },
                                             secureInput: SecureInput.blocker, sendPaste: Inserter.postCmdV)
            busy = false
            if let error = run.error { fail(error) } else { indicator.set(.idle) }
        }
    }

    private func fail(_ message: String) {
        indicator.set(.error)
        indicator.show(message, seconds: 4)
    }

    // MARK: setup

    private func loadEngine() async {
        do {
            let e = try await Speech.load()
            engine = e
            engineStatus = EngineLabel.status(e.name)
        } catch {
            NSLog("shepetal: speech: %@", error.localizedDescription)  // model names stay in the log
            engineStatus = ParakeetEngine.isInstalled ? "On-device speech recognition could not start"
                                                      : "On-device speech recognition is not downloaded yet"
            fail("No speech recognition. Open the 🤫 menu.")
        }
    }

    private func startTapIfAllowed() {
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
        menu.addItem(withTitle: tap.isRunning ? "Hold fn to talk, double-tap for hands-free" : "fn is not being watched yet", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: engineStatus, action: nil, keyEquivalent: "")
        menu.addItem(item("Open Shepetal…", #selector(openHub)))
        Account.shared.menuItems().forEach(menu.addItem)
        if engine == nil, !ParakeetEngine.isInstalled {
            menu.addItem(item("Download on-device speech recognition (about 470 MB)", #selector(downloadModel)))
        }
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

    /// Opening the app again while it runs (Finder, Spotlight, `open`) shows the hub.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHub()
        return false
    }

    @objc private func openHub() {
        guard let pipeline else { return fail("History is not available") }
        hub = hub ?? Hub(pipeline: pipeline, engine: { [weak self] in self?.engine },
                         status: { [weak self] in (self?.engineStatus ?? "", self?.tap.isRunning == true) },
                         retention: { [weak self] in self?.retention ?? .keep },
                         setRetention: { [weak self] in self?.retention = $0 },
                         openPermissions: { [weak self] in self?.showOnboarding() },
                         meetingStore: meetingFlow?.store ?? InMemoryMeetingStore())
        hub?.show()
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

    @objc private func downloadModel() {
        engineStatus = "Downloading on-device speech recognition…"
        Task {
            do { try await ParakeetEngine.download() } catch { engineStatus = "Download failed: " + (SpeechError(plain: error, "check the internet connection and try again").errorDescription ?? ""); return }
            await loadEngine()
        }
    }
}
