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
    private var gesture = FnGesture()
    private var pipeline: Pipeline?
    private var engine: SpeechEngine?
    private var engineStatus = "Loading speech model…"
    private var busy = false
    private var recording = false
    private var tick: DispatchWorkItem?
    private var onboarding: Onboarding?
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

        do { pipeline = try Pipeline() } catch { fail("Storage: \(error.localizedDescription)") }
        applyRetention()
        tap.onChange = { [weak self] down in self?.fn(down) }
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
    }

    // MARK: fn → gestures

    private func fn(_ down: Bool) {
        let t = ProcessInfo.processInfo.systemUptime
        if down, busy, gesture.state == .idle {
            indicator.show("Still transcribing the last one", seconds: Hint.seconds)
            return
        }
        for action in down ? gesture.fnDown(at: t) : gesture.fnUp(at: t) { handle(action) }
        scheduleTick()
    }

    private func scheduleTick() {
        tick?.cancel()
        guard let deadline = gesture.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for action in self.gesture.tick(at: ProcessInfo.processInfo.systemUptime) { self.handle(action) }
            }
        }
        tick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    private func handle(_ action: GestureAction) {
        switch action {
        case .start:
            guard Recorder.micAllowed else {
                gesture.reset()
                if allowPrompts { Permission.microphone.request() }
                return fail("Microphone access is off")
            }
            do {
                try recorder.start()
                recording = true
                indicator.set(.recording)
            } catch {
                gesture.reset()
                fail("Microphone: \(error.localizedDescription)")
            }
        case .lockHandsFree:
            indicator.set(.handsFree)
        case .tooShort:
            pipeline?.keep(stopRecording(), as: .tooShort)
            indicator.set(.idle)
            indicator.show(Hint.shortPress, seconds: Hint.seconds)
        case .stop:
            let samples = stopRecording()
            guard let pipeline else { return }
            busy = true
            indicator.set(.processing)
            Task {
                let run = await pipeline.process(samples, engine: engine, context: FocusedText.context,
                                                 sendPaste: Inserter.postCmdV)
                busy = false
                if let error = run.error { fail(error) } else { indicator.set(.idle) }
            }
        }
    }

    private func stopRecording() -> [Float] {
        guard recording else { return [] }
        recording = false
        return recorder.stop()
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
