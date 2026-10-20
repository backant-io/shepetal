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
    private var shortcuts: ShortcutsWindow?
    private var transcription: Task<Void, Never>?
    private var inserting = false  // the paste is under way, too late for Esc
    private var timers: [Timer] = []

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
        let minutes = UserDefaults.standard.integer(forKey: "maxDictationMinutes")
        if minutes > 0 { dictation?.gesture.maxDuration = TimeInterval(minutes * 60) }
        tap.router.shortcuts = ShortcutsWindow.saved
        tap.isActive = { [weak self] in MainActor.assumeIsolated { self.map { $0.busy || $0.dictation?.gesture.state != .idle } ?? false } }
        // Off the tap callback: opening the mic is slow, and a slow callback gets the tap turned off.
        tap.onInput = { [weak self] input in DispatchQueue.main.async { MainActor.assumeIsolated { self?.key(input) } } }
        startTapIfAllowed()
        // Retention runs hourly; the tap starts as soon as Input Monitoring is granted.
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTapIfAllowed() }
        })
        Task { await loadEngine() }

        if !Permission.missing.isEmpty {
            if allowPrompts { showOnboarding() } else { fail("Needs \(Permission.missing.map(\.title).joined(separator: ", "))") }
        }
        if hintAtLaunch { indicator.show(Hint.shortPress, seconds: Hint.seconds) }
        if CommandLine.arguments.contains("--show-shortcuts") { openShortcuts() }
    }

    // MARK: keys → gestures

    private func key(_ input: KeyInput) {
        let t = ProcessInfo.processInfo.systemUptime
        let idle = dictation?.gesture.state == .idle
        switch input {
        case .pasteLast: pasteLast()
        case .copyLast: copyLast()
        case .recorded(let chord): shortcuts?.recorded(chord)
        case .dismiss where idle:
            // Esc while transcribing: Pipeline inserts nothing and keeps the row as cancelled.
            guard let transcription, !inserting else { return }
            transcription.cancel()
            indicator.show(Hint.cancelled, seconds: Hint.seconds)
        case .pttDown where busy && idle, .toggle where busy && idle:
            indicator.show("Still transcribing the last one", seconds: Hint.seconds)
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
        case .start: indicator.set(.recording)
        case .lockHandsFree: indicator.set(.handsFree)
        case .tooShort:
            indicator.set(.idle)
            indicator.show(Hint.shortPress, seconds: Hint.seconds)
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
        do { try recorder.start() } catch { throw SpeechError("Microphone: \(error.localizedDescription)") }
    }

    private func transcribe(_ samples: [Float]) {
        guard let pipeline else { return }
        busy = true
        indicator.set(.processing)
        transcription = Task {
            // Pipeline reads the context right after its last cancel check; a cancel during the paste
            // would cut the paste's waits short.
            let run = await pipeline.process(samples, engine: engine, context: { [weak self] in
                self?.inserting = true
                return FocusedText.context()
            }, sendPaste: Inserter.postCmdV)
            busy = false
            inserting = false
            transcription = nil
            if let error = run.error, !Task.isCancelled { fail(error) } else { indicator.set(.idle) }
        }
    }

    /// Paste last / copy last: the newest history text, a paste that did not land included.
    private func lastHistoryText() -> String? {
        let text = lastText(in: (try? pipeline?.history.recent(limit: 50)) ?? [])
        if text == nil { indicator.show(Hint.nothingToPaste, seconds: Hint.seconds) }
        return text
    }

    private func pasteLast() {
        guard let pipeline, !busy, let text = lastHistoryText() else { return }
        busy = true
        Task {
            let paste = await pipeline.inserter.insert(text, sendPaste: Inserter.postCmdV)
            busy = false
            if !paste.landed { fail("Paste did not land. The text is on the clipboard: press ⌘V to paste it.") }
        }
    }

    private func copyLast() {
        guard let text = lastHistoryText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        indicator.show("Copied", seconds: 1.5)
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
        if tap.isRunning, !tap.canSwallow, Permission.accessibility.granted { tap.stop() }  // listen-only → active
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
