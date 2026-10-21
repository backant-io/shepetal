import AppKit
import ServiceManagement

// shepetal                           menu-bar app
// shepetal --no-permission-prompts   never asks macOS for a permission (checks only)
// shepetal --show-hint               shows the short-press hint once at launch (for screenshots)
// shepetal --e2e <wav>... [--engine fallback] [--drop-paste]   real pipeline on audio files, JSON lines out
// shepetal --e2e-meeting <me.wav> <others.wav>   meeting transcriber, store and summary on two files, JSON out
// shepetal --quit-from-menu-after <s>   after <s> seconds, picks "Quit shepetal" from the real status menu
//                                       (the release check that Quit works; nothing is clicked on screen)
// shepetal --unregister-login-item    run by the uninstaller: turns Start at login off, then exits
let args = CommandLine.arguments
ParakeetEngine.stayOffline()  // before any model load, in every mode (#78)
if let i = args.firstIndex(of: "--e2e-meeting") { MeetingE2E.main(Array(args[(i + 1)...])) }
if args.contains("--unregister-login-item") {
    let service = SMAppService.mainApp
    do {
        if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
    } catch {
        print("login item: \(error.localizedDescription)")
    }
    let status = switch service.status {
    case .enabled: "enabled"
    case .requiresApproval: "requires approval in System Settings > General > Login Items"
    case .notRegistered: "not registered"
    default: "not found"
    }
    print("login item: \(status)")
    exit(0)
}
MainActor.assumeIsolated {
    let delegate: NSApplicationDelegate
    if let i = args.firstIndex(of: "--e2e") {
        let wavs = args[(i + 1)...].prefix { !$0.hasPrefix("--") }
        let engine = args.firstIndex(of: "--engine").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        delegate = E2E(wavs: Array(wavs), fallback: engine == "fallback", dropPaste: args.contains("--drop-paste"))
    } else {
        delegate = AppDelegate(allowPrompts: !args.contains("--no-permission-prompts"),
                               hintAtLaunch: args.contains("--show-hint"))
    }
    let app = NSApplication.shared
    app.delegate = delegate
    if let app = delegate as? AppDelegate, let i = args.firstIndex(of: "--quit-from-menu-after"),
       args.indices.contains(i + 1), let seconds = Double(args[i + 1]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { quitFromStatusMenu(app) }
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}

/// Opens the app's real status item menu the way AppKit does before showing it (its delegate's
/// menuNeedsUpdate), checks the menu-bar 🤫 is there, and performs "Quit shepetal". Exits 3 on a failure.
@MainActor
private func quitFromStatusMenu(_ app: AppDelegate) {
    func fail(_ why: String) -> Never {
        FileHandle.standardError.write(Data("quit-from-menu: \(why)\n".utf8))
        exit(3)
    }
    let item = Mirror(reflecting: app).children.first { $0.label == "statusItem" }?.value as? NSStatusItem
    guard let item else { fail("no status item") }
    guard item.isVisible, item.button?.title == "🤫", item.button?.window != nil else {
        fail("the menu-bar 🤫 is not shown (title \(item.button?.title ?? "nil"))")
    }
    guard let menu = item.menu else { fail("the status item has no menu") }
    guard let delegate = menu.delegate else { fail("the status menu has no delegate") }
    delegate.menuNeedsUpdate?(menu)
    guard let quit = menu.items.firstIndex(where: { $0.title == "Quit shepetal" }) else {
        fail("no Quit shepetal item in the menu")
    }
    FileHandle.standardError.write(Data("quit-from-menu: menu-bar 🤫 shown, \(menu.items.count) menu items, picking Quit shepetal\n".utf8))
    menu.performActionForItem(at: quit)
}
