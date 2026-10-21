import AppKit
import ShepetalCore

/// F99: `Shepetal --watchdog <pid>` is a second copy of the binary that waits for the app to exit. An exit
/// without the clean-quit marker is a crash, and the app is opened again after `Relaunch`'s backoff. Quit,
/// any `exit`, and SIGTERM (the installer, the uninstaller, `kill`) write the marker, so the app stays quit.
enum Watchdog {
    static let flag = "--watchdog"
    private static var home: URL?  // read by the atexit handler, which cannot capture
    private static var sigterm: DispatchSourceSignal?
    private static var child: Process?

    /// Only a normal launch of the bundled app: every `--` flag is a test or installer mode, and outside an
    /// .app bundle there is nothing to open again.
    static func wanted(args: [String], bundle: URL) -> Bool {
        bundle.pathExtension == "app" && !args.dropFirst().contains { $0.hasPrefix("--") }
    }

    /// The app side, first thing at launch. Returns `Relaunch.gaveUpHint` once, at the launch after a give-up.
    @MainActor static func start(args: [String] = CommandLine.arguments, dir: URL = Paths.root) -> String? {
        guard wanted(args: args, bundle: Bundle.main.bundleURL), let exe = Bundle.main.executableURL else { return nil }
        // The crash count and the marker live here. Without the folder every crash would look like the first
        // and every Quit like a crash, so a watchdog that cannot write it would reopen the app forever.
        guard (try? AudioStore.makeOwnerOnlyDirectory(dir)) != nil else { return nil }
        let p = Process()
        p.executableURL = exe
        p.arguments = [flag, String(getpid())]  // scripts/pkg/preinstall and uninstall-mac.sh match this command line
        do { try p.run(); child = p } catch {
            NSLog("shepetal: watchdog did not start: %@", String(describing: error))
            return takeGaveUp(dir: dir)
        }
        home = dir
        atexit { Watchdog.quitting() }  // any exit() that did not go through applicationWillTerminate
        signal(SIGTERM, SIG_IGN)  // handled below instead
        // Off the main thread, so SIGTERM still ends an app whose main thread hangs, and at once (_exit runs no
        // exit handlers), as it did before.
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { quitting(); _exit(0) }
        source.resume()
        sigterm = source
        return takeGaveUp(dir: dir)
    }

    /// Quit calls this first in applicationWillTerminate, before any teardown that could crash. It does
    /// nothing when no watchdog runs (the test and installer modes).
    static func quitting() { if let home { markCleanQuit(dir: home) } }

    /// Tells the watchdog that `pid` is quitting on purpose, so its exit is not a crash.
    static func markCleanQuit(dir: URL, pid: pid_t = getpid()) {
        try? String(pid).write(to: dir.appendingPathComponent("clean-quit"), atomically: true, encoding: .utf8)
    }

    /// `Shepetal --watchdog <pid>`, from main.swift. Never returns.
    static func main(_ args: [String]) -> Never {
        signal(SIGTERM, SIG_DFL)  // a child inherits an ignored SIGTERM; pkill must stop this process
        guard let pid = args.first.flatMap({ pid_t($0) }) else { exit(2) }
        let source = watch(pid: pid, dir: Paths.root, relaunch: { reopen(Bundle.main.bundleURL) }, stay: { exit(0) })
        withExtendedLifetime(source) { dispatchMain() }
    }

    /// Waits for `pid` to exit, records the exit in `dir`/relaunch.json, then calls `relaunch` after the
    /// backoff, or `stay` after a clean quit or a give-up. Keep the returned source until then.
    static func watch(pid: pid_t, dir: URL, queue: DispatchQueue = .main, started: Date = Date(),
                      relaunch: @escaping () -> Void, stay: @escaping () -> Void) -> DispatchSourceProcess {
        // Fires once, also for a pid that is already gone (the app crashed before this started to watch).
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler {
            let marker = dir.appendingPathComponent("clean-quit")
            let clean = (try? String(contentsOf: marker, encoding: .utf8)) == String(pid)
            if clean { try? FileManager.default.removeItem(at: marker) }
            var policy = load(dir)
            let delay = policy.exited(clean: clean, ran: Date().timeIntervalSince(started))
            save(policy, dir)
            if let delay { queue.asyncAfter(deadline: .now() + delay, execute: relaunch) } else { stay() }
        }
        source.resume()
        return source
    }

    /// The launch after a give-up says so, once.
    static func takeGaveUp(dir: URL) -> String? {
        var policy = load(dir)
        guard policy.gaveUp else { return nil }
        policy.gaveUp = false
        save(policy, dir)
        return Relaunch.gaveUpHint
    }

    private static func load(_ dir: URL) -> Relaunch {
        (try? Data(contentsOf: dir.appendingPathComponent("relaunch.json")))
            .flatMap { try? JSONDecoder().decode(Relaunch.self, from: $0) } ?? Relaunch()
    }

    private static func save(_ policy: Relaunch, _ dir: URL) {
        try? JSONEncoder().encode(policy).write(to: dir.appendingPathComponent("relaunch.json"), options: .atomic)
    }

    /// In the background, so the window in use keeps focus. An app opened by hand meanwhile is left alone.
    private static func reopen(_ app: URL) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        guard app.pathExtension == "app", !others.contains(where: { $0.processIdentifier != getpid() }) else { exit(0) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            if let error { NSLog("shepetal: watchdog could not open the app again: %@", String(describing: error)) }
            exit(error == nil ? 0 : 1)
        }
    }
}
