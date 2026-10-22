import AppKit
import ServiceManagement
import ShepetalCore
import Sparkle
import SwiftUI

/// Sparkle 2 behind Check for Updates… (docs/install-and-update.md 3). Only release builds have a feed (make-app.sh
/// with UPDATES=1 writes SUFeedURL and SUPublicEDKey); every other build keeps `NoUpdateChecker`. Ask first (Pavel,
/// 22.10.26): its own user driver, so Sparkle never opens a window. A found update is the card above the meeting card
/// (`MeetingCard.update`), never up while Shepetal works (`UpdatePrompt`), and nothing downloads or installs before
/// Install Now. A card, not an alert: an alert takes focus from the app Shepetal pastes into.
@MainActor
final class SparkleUpdater: NSObject, UpdateChecking, SPUUpdaterDelegate, SPUUserDriver {
    /// `defaults write io.backant.shepetal ShepetalFeedURL https://…/appcast.xml` tests an update on one Mac.
    static let feedOverrideKey = "ShepetalFeedURL"
    private var updater: SPUUpdater!
    private let activity: () -> Activity
    private let hint: (String) -> Void
    private var relaunch: (() -> Void)?
    private var timer: Timer?
    private var prompt = UpdatePrompt()
    /// Sparkle's question about the found update, answered once: install or dismiss, never skip (that skips the
    /// version for good).
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    private lazy var card = MeetingCard.update(onInstall: { [weak self] in self?.answer(.install) },
                                               onLater: { [weak self] in self?.answer(.dismiss) })

    static func make(activity: @escaping () -> Activity, hint: @escaping (String) -> Void) -> any UpdateChecking {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil else { return NoUpdateChecker() }
        return SparkleUpdater(activity: activity, hint: hint)
    }

    private init(activity: @escaping () -> Activity, hint: @escaping (String) -> Void) {
        self.activity = activity
        self.hint = hint
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do { try updater.start() } catch { hint("Updates are off: \(error.localizedDescription)") }
        // Every second, so the card is down within a second of a dictation or recording starting.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Always: the item is never greyed out. A click while Sparkle cannot check says why instead.
    var canCheckForUpdates: Bool { true }
    var menuTitle: String { prompt.version.map { "Update to \($0)…" } ?? "Check for Updates…" }
    func checkForUpdates() {
        if prompt.version != nil { return showUpdateInFocus() }
        // Sparkle's own canCheckForUpdates is false while it checks or downloads.
        guard updater.canCheckForUpdates else { return hint("Shepetal is downloading an update") }
        updater.checkForUpdates()
    }

    private func tick() {
        let now = Date(), a = activity()
        if prompt.expired(now: now) { answer(.dismiss) }
        let was = prompt.showing
        if prompt.update(a, now: now) != was { card.show(prompt.showing ? prompt.version : nil) }
        if let go = relaunch, UpdateGate.allows(a, now: now, manual: true) { relaunch = nil; go() }
    }

    /// Install Now or Later. Later downloads nothing, and the next daily check asks again.
    private func answer(_ choice: SPUUserUpdateChoice) {
        prompt = UpdatePrompt()
        card.show(nil)
        let r = reply
        reply = nil
        r?(choice)
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let url = UserDefaults.standard.string(forKey: Self.feedOverrideKey), url.hasPrefix("https://") else { return nil }
        return url
    }

    /// After Install Now: the relaunch waits only for the work under way.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let a = activity()
        guard !UpdateGate.allows(a, now: Date(), manual: true) else { return false }
        relaunch = installHandler
        if let waiting = UpdateGate.waiting(a) { hint(waiting) }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let e = error as NSError
        if e.domain == SUSparkleErrorDomain, let notice = UpdateGate.failure(code: e.code, e.localizedDescription) { hint(notice) }
    }

    // MARK: SPUUserDriver: the card, and hints next to 🤫. Sparkle calls these on the main thread.

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate else { return reply(.dismiss) }
        prompt.version = appcastItem.displayVersionString
        prompt.found = Date()
        prompt.manual = state.userInitiated
        self.reply = reply
        tick()
    }

    /// Reached only after Install Now.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }

    /// Check for Updates… while the found update waits: the card at once, or as soon as the work ends.
    func showUpdateInFocus() {
        prompt.manual = true
        tick()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { hint("Shepetal is downloading the update") }

    /// Only after a manual check.
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        hint("Shepetal is up to date")
        acknowledgement()
    }

    /// After a manual check or Install Now. `didAbortWithError` already says what `UpdateGate.failure` covers.
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let e = error as NSError
        if e.domain != SUSparkleErrorDomain || UpdateGate.failure(code: e.code, e.localizedDescription) == nil {
            hint("Update failed: \(e.localizedDescription)")
        }
        acknowledgement()
    }

    /// Sparkle ends the session: answered, failed or done.
    func dismissUpdateInstallation() {
        prompt = UpdatePrompt()
        reply = nil
        card.show(nil)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
}

/// Offers once per version to move a copy run from the DMG, Downloads or App Translocation to /Applications
/// (`MovePrompt`), then opens the copy there and quits. Returns true when this instance is quitting.
@MainActor
enum MoveToApplications {
    static func offerIfNeeded() -> Bool {
        let here = Bundle.main.bundleURL
        let d = UserDefaults.standard, fm = FileManager.default
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard MovePrompt.offers(path: here.path, home: NSHomeDirectory(), readOnlyVolume: readOnly(here),
                                bundleID: Bundle.main.bundleIdentifier ?? "", asked: MovePrompt.asked(d, version: version))
        else { return false }
        MovePrompt.remember(d, version: version)
        let alert = NSAlert()
        alert.messageText = "Move Shepetal to Applications?"
        alert.informativeText = "It updates itself only from there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let build = { (b: Bundle?) in Int(b?.infoDictionary?["CFBundleVersion"] as? String ?? "") }
        let ours = { (u: URL) in Bundle(url: u).flatMap { $0.bundleIdentifier == UninstallPlan.bundleID ? build($0) : nil } }
        let running = build(Bundle.main) ?? 0
        let dest = URL(fileURLWithPath: MovePrompt.destination(home: NSHomeDirectory(), writable: fm.isWritableFile(atPath:),
                                                               exists: fm.fileExists(atPath:),
                                                               systemBuild: ours(URL(fileURLWithPath: MovePrompt.system)),
                                                               runningBuild: running))
        let source = original(here)
        do {
            let move = MovePrompt.move(installedBuild: ours(dest), runningBuild: running)
            switch move {
            case .openInstalled: break
            case .replace:
                try fm.trashItem(at: dest, resultingItemURL: nil)
                try copy(here, to: dest)
            case .copy:
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)  // ~/Applications
                try copy(here, to: dest)
            }
            // A move leaves no copy behind (LetsMove does the same); the DMG's stays.
            if move != .openInstalled, !readOnly(source) { try? fm.trashItem(at: source, resultingItemURL: nil) }
        } catch {
            let fail = NSAlert()
            fail.messageText = "Shepetal could not move itself"
            fail.informativeText = "\(error.localizedDescription)\nDrag Shepetal into Applications in Finder instead."
            fail.runModal()
            return false
        }
        // The old .pkg's root-owned copy (not newer: `destination` would have opened it). On a standard account the copy
        // there is an admin's, shared by every account, so nothing is said.
        if dest.path != MovePrompt.system, fm.fileExists(atPath: MovePrompt.system), fm.isWritableFile(atPath: "/Applications") {
            let old = NSAlert()
            old.messageText = "shepetal is now in your own Applications folder"
            old.informativeText = "The copy in /Applications needs an administrator password to remove. Move it to the Trash in Finder."
            old.runModal()
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", dest.path]
        guard (try? open.run()) != nil else { return false }
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { return false }
        NSApp.terminate(nil)
        return true
    }

    /// The DMG. A translocated bundle reads as read-only too, so ask this of `original(_:)`.
    private static func readOnly(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// Where a translocated bundle really is, e.g. ~/Downloads/Shepetal.app. Security's
    /// SecTranslocateCreateOriginalPathForURL has no Swift header, so it is looked up at run time, as LetsMove does.
    static func original(_ url: URL) -> URL {
        guard url.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        return unsafeBitCast(sym, to: Original.self)(url as CFURL, nil)?.takeRetainedValue() as URL? ?? url
    }

    /// The user already chose this download, so the copy loses its quarantine flag.
    private static func copy(_ from: URL, to: URL) throws {
        try FileManager.default.copyItem(at: from, to: to)
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", to.path]
        try x.run()
        x.waitUntilExit()
    }
}

/// Runs an `UninstallPlan`. Nothing is deleted: files go to the Trash.
@MainActor
enum Uninstaller {
    static var bundleOffered: Bool {
        let url = Bundle.main.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        return UninstallPlan.offered(bundleID: Bundle.main.bundleIdentifier ?? "", readOnlyVolume: readOnly == true)
    }

    static func plan(deleteData: Bool) -> [UninstallStep] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var apps: [URL] = []
        for url in [Bundle.main.bundleURL] + ["/Applications", home.path + "/Applications"]
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("Shepetal.app") })
            .filter({ Bundle(url: $0)?.bundleIdentifier == UninstallPlan.bundleID }) {
            let u = url.resolvingSymlinksInPath()
            if !apps.contains(u) { apps.append(u) }
        }
        return UninstallPlan.steps(fnKeyRestorable: FnKeySystem.enabled && FnKeySetting.restorable(FnKeySystem.io) != nil,
                                   deleteData: deleteData,
                                   models: [ParakeetEngine.directory, KeywordBooster.directory, Paths.models],
                                   caches: home.appendingPathComponent("Library/Caches/\(UninstallPlan.bundleID)"),
                                   data: Paths.root, apps: apps)
    }

    static func run(_ steps: [UninstallStep]) {
        var trash: [URL] = []
        for step in steps {
            switch step {
            case .unregisterLoginItem: try? SMAppService.mainApp.unregister()
            case .restoreFnKey: _ = FnKeySetting.restore(FnKeySystem.io)
            case .signOut: Account.shared.signOut()
            case .resetPrivacy: shell("/usr/bin/tccutil", "reset", "All", UninstallPlan.bundleID)  // best effort
            case .cancelPendingUpdate: shell("/bin/launchctl", "remove", "\(UninstallPlan.bundleID)-sparkle-updater")
            case .stopWatchdog: Watchdog.stop()
            case .trash(let url): if FileManager.default.fileExists(atPath: url.path) { trash.append(url) }
            case .deleteSettings: UserDefaults.standard.removePersistentDomain(forName: UninstallPlan.bundleID)
            case .quit: break
            }
        }
        guard !trash.isEmpty else { return NSApp.terminate(nil) }
        // One call, so a root-owned copy from the old .pkg gets Finder's own password prompt.
        NSWorkspace.shared.recycle(trash) { moved, error in
            if let error { NSLog("shepetal: uninstall: %@ (moved %d of %d)", error.localizedDescription, moved.count, trash.count) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func shell(_ path: String, _ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

/// The last, quiet line of Settings: a small grey link, never in the 🤫 menu, so it is not clicked by accident.
struct UninstallSection: View {
    let blocker: () -> String?
    @State private var asking = false

    var body: some View {
        if Uninstaller.bundleOffered {
            Section {
                Button("Uninstall Shepetal…") { asking = true }
                    .buttonStyle(.link).foregroundStyle(.secondary).font(.caption)
            }
            .sheet(isPresented: $asking) { UninstallSheet(blocker: blocker) { asking = false } }
        }
    }
}

private struct UninstallSheet: View {
    let blocker: () -> String?
    let close: () -> Void
    @State private var deleteData = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in content(blocker()) }  // a dictation can start meanwhile
    }

    private func content(_ blocker: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Uninstall Shepetal?").font(.headline)
            Text("Shepetal will:")
            VStack(alignment: .leading, spacing: 2) {
                Text("• stop starting at login")
                if FnKeySystem.enabled, let previous = FnKeySetting.restorable(FnKeySystem.io) {
                    Text("• put back your 🌐 key setting (\(FnKeySetting.describe(previous)))")
                }
                Text("• sign out on this Mac")
                Text("• move Shepetal and the models it downloaded (1 GB or more) to the Trash")
                Text("• quit")
            }
            Text(deleteData ? "Your recordings, transcripts and history also go to the Trash."
                            : "Your recordings, transcripts and history stay in ~/Library/Application Support/Shepetal.")
                .foregroundStyle(.secondary)
            Toggle("Also delete my recordings", isOn: $deleteData)
            if let blocker { Text(blocker).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.defaultAction)  // Return cancels
                Button("Uninstall", role: .destructive) {
                    guard self.blocker() == nil else { return }
                    close()
                    Uninstaller.run(Uninstaller.plan(deleteData: deleteData))
                }
                    .disabled(blocker != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onExitCommand(perform: close)  // and so does Esc
    }
}
