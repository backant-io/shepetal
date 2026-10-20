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
    private var engineStatus = "Loading speech model…"
    private var busy = false
    private var tick: DispatchWorkItem?
    private var onboarding: Onboarding?
    private var timers: [Timer] = []
    private let focus = FocusRestore()
    private let sounds = Sounds()
    private lazy var secureInput = SecureInput(indicator: indicator)
    private var permissions: PermissionMonitor!
    private lazy var loginItem = LoginItem { [weak self] in self?.indicator.show($0, seconds: 6) }

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

        do { pipeline = try Pipeline() } catch { fail("Storage: \(error.localizedDescription)") }
        if let pipeline {
            dictation = Dictation(store: pipeline.store, history: pipeline.history,
                                  startMic: { [weak self] in try self?.openMic() },
                                  stopMic: { [recorder] in recorder.stop() },
                                  transcribe: { [weak self] in self?.transcribe($0) })
        }
        applyRetention()
        tap.onChange = { [weak self] down in self?.fn(down) }
        tap.onOtherKey = { [weak self] in self?.run { $0.otherKeyDown(at: ProcessInfo.processInfo.systemUptime) } }
        startTapIfAllowed()
        // Retention runs hourly; the tap starts as soon as Input Monitoring is granted.
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTapIfAllowed(); self?.secureInput.check(); self?.permissions.check() }
        })
        Task { await loadEngine() }

        permissions = PermissionMonitor { [weak self] message in
            self?.fail(message)
            if self?.allowPrompts == true { self?.showOnboarding() }
        }
        if !Permission.missing.isEmpty {
            if allowPrompts { showOnboarding() } else { fail("Needs \(Permission.missing.map(\.title).joined(separator: ", "))") }
        }
        if hintAtLaunch { indicator.show(Hint.shortPress, seconds: Hint.seconds) }
    }

    // MARK: fn → gestures

    private func fn(_ down: Bool) {
        let t = ProcessInfo.processInfo.systemUptime
        if down, busy, dictation?.gesture.state == .idle {
            indicator.show("Still transcribing the last one", seconds: Hint.seconds)
            return
        }
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
        sounds.play(action)
        switch action {
        case .start:
            focus.store()
            indicator.set(.recording)
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
        do { try recorder.start() } catch { throw SpeechError("Microphone: \(error.localizedDescription)") }
    }

    private func transcribe(_ samples: [Float]) {
        guard let pipeline else { return }
        busy = true
        indicator.set(.processing)
        Task {
            let run = await pipeline.process(samples, engine: engine, context: FocusedText.context,
                                             selection: FocusedText.selected, refocus: focus.restore,
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
            engineStatus = "Model: \(e.name)"
        } catch {
            engineStatus = error.localizedDescription
            fail("No speech model. Open the 🤫 menu.")
        }
    }

    private func startTapIfAllowed() {
        guard !tap.isRunning, Permission.inputMonitoring.granted else { return }
        if tap.start(), indicator.mode == .error, Permission.missing.isEmpty { indicator.set(.idle) }
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
        if engine == nil, !ParakeetEngine.isInstalled {
            menu.addItem(item("Download speech model (Parakeet v3, about 470 MB)", #selector(downloadModel)))
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
        menu.addItem(sounds.menuItem)
        menu.addItem(loginItem.menuItem)
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

    @objc private func openRecordings() { NSWorkspace.shared.open(Paths.audio) }
    @objc private func openPermissions() { showOnboarding() }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    @objc private func downloadModel() {
        engineStatus = "Downloading Parakeet v3…"
        Task {
            do { try await ParakeetEngine.download() } catch { engineStatus = "Download failed: \(error.localizedDescription)"; return }
            await loadEngine()
        }
    }
}
