import AppKit
import ServiceManagement
import ShepetalCore
import Sparkle
import SwiftUI

/// Sparkle 2 behind Check for Updates… (docs/install-and-update.md 3). Only release builds have a feed (make-app.sh
/// with UPDATES=1 writes SUFeedURL and SUPublicEDKey); every other build keeps `NoUpdateChecker`. A downloaded update
/// installs only when `UpdateGate` allows it, or when Shepetal quits.
@MainActor
final class SparkleUpdater: NSObject, UpdateChecking, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    /// `defaults write io.backant.shepetal ShepetalFeedURL https://…/appcast.xml` tests an update on one Mac.
    static let feedOverrideKey = "ShepetalFeedURL"
    private var controller: SPUStandardUpdaterController!
    private let activity: () -> Activity
    private let hint: (String) -> Void
    private var installNow: (() -> Void)?
    private var relaunch: (() -> Void)?
    private var timer: Timer?
    /// "Update to 0.2.1…" when automatic install is off and a scheduled check found one.
    private var found: String?

    static func make(activity: @escaping () -> Activity, hint: @escaping (String) -> Void) -> any UpdateChecking {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil else { return NoUpdateChecker() }
        return SparkleUpdater(activity: activity, hint: hint)
    }

    private init(activity: @escaping () -> Activity, hint: @escaping (String) -> Void) {
        self.activity = activity
        self.hint = hint
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Always: the item is never greyed out. A click while Sparkle cannot check says why instead.
    var canCheckForUpdates: Bool { true }
    var menuTitle: String { found ?? "Check for Updates…" }
    func checkForUpdates() {
        // Sparkle's own canCheckForUpdates is false only while it downloads the feed or an update in the background.
        guard controller.updater.canCheckForUpdates else { return hint("Shepetal is downloading an update") }
        controller.checkForUpdates(nil)
    }

    /// Settings › Install updates automatically.
    var automaticallyInstalls: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    private func tick() {
        let now = Date()
        if let install = installNow, UpdateGate.allows(activity(), now: now) { installNow = nil; install() }
        if let go = relaunch, UpdateGate.allows(activity(), now: now, manual: true) { relaunch = nil; go() }
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let url = UserDefaults.standard.string(forKey: Self.feedOverrideKey), url.hasPrefix("https://") else { return nil }
        return url
    }

    /// Downloaded in the background: keep the block and run it once Shepetal is idle. Quitting installs it anyway.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        installNow = immediateInstallationBlock
        tick()
        return true
    }

    /// Install and Relaunch from the dialog: waits only for the work under way.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let a = activity()
        guard !UpdateGate.allows(a, now: Date(), manual: true) else { return false }
        relaunch = installHandler
        if let waiting = UpdateGate.waiting(a) { hint(waiting) }
        return true
    }

    // MARK: SPUStandardUserDriverDelegate: gentle reminders, so no update window opens at a random moment

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { found = "Update to \(update.displayVersionString)…" }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { found = nil }

    func standardUserDriverWillFinishUpdateSession() { found = nil }
}

/// Offers once to move a copy run from the DMG, Downloads or App Translocation to /Applications (`MovePrompt`), then
/// opens the copy there and quits. Returns true when this instance is quitting.
@MainActor
enum MoveToApplications {
    static func offerIfNeeded() -> Bool {
        let here = Bundle.main.bundleURL
        let readOnly = (try? here.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        let d = UserDefaults.standard
        guard MovePrompt.offers(path: here.path, home: NSHomeDirectory(), readOnlyVolume: readOnly == true,
                                bundleID: Bundle.main.bundleIdentifier ?? "", asked: d.bool(forKey: MovePrompt.askedKey))
        else { return false }
        d.set(true, forKey: MovePrompt.askedKey)
        let alert = NSAlert()
        alert.messageText = "Move Shepetal to Applications?"
        alert.informativeText = "It updates itself only from there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let dest = URL(fileURLWithPath: "/Applications/Shepetal.app")
        let build = { (b: Bundle?) in Int(b?.infoDictionary?["CFBundleVersion"] as? String ?? "") }
        let installed = Bundle(url: dest).flatMap { $0.bundleIdentifier == UninstallPlan.bundleID ? build($0) : nil }
        do {
            switch MovePrompt.move(installedBuild: installed, runningBuild: build(Bundle.main) ?? 0) {
            case .openInstalled: break
            case .replace:
                try FileManager.default.trashItem(at: dest, resultingItemURL: nil)
                try copy(here, to: dest)
            case .copy: try copy(here, to: dest)
            }
        } catch {
            // ponytail: no admin prompt for a root-owned copy from the old .pkg; the message says what to do instead.
            let fail = NSAlert()
            fail.messageText = "Shepetal could not move itself"
            fail.informativeText = "\(error.localizedDescription)\nDrag Shepetal into Applications in Finder instead."
            fail.runModal()
            return false
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
