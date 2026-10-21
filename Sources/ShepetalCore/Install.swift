import Foundation

/// What Shepetal is doing right now, for the updater (when an update may install) and Uninstall (when it may run).
public struct Activity: Equatable {
    public var dictating = false
    /// A meeting recording, or its final transcription and summary.
    public var meeting = false
    /// A re-transcribe in History.
    public var retranscribing = false
    public var lastFnPress: Date?

    public init(dictating: Bool = false, meeting: Bool = false, retranscribing: Bool = false, lastFnPress: Date? = nil) {
        self.dictating = dictating; self.meeting = meeting; self.retranscribing = retranscribing; self.lastFnPress = lastFnPress
    }

    /// The work under way, as "the meeting" in "when the meeting ends"; nil when idle.
    public var work: String? {
        if meeting { return "the meeting" }
        if dictating { return "the dictation" }
        if retranscribing { return "the re-transcribe" }
        return nil
    }
}

/// When a downloaded update may install (docs/install-and-update.md 3): never during work, and only once fn has been
/// left alone for 20 minutes (Wispr Flow's rule, docs/re/app-architecture.md 9). A manual Install and Relaunch only
/// waits for the work to end.
public enum UpdateGate {
    public static let quiet: TimeInterval = 20 * 60

    public static func allows(_ a: Activity, now: Date, manual: Bool = false) -> Bool {
        guard a.work == nil else { return false }
        guard !manual, let last = a.lastFnPress else { return true }
        return now.timeIntervalSince(last) >= quiet
    }

    /// Next to 🤫 while a manual install waits.
    public static func waiting(_ a: Activity) -> String? { a.work.map { "Shepetal restarts to update when \($0) ends" } }
}

/// The first-run window (docs/install-and-update.md 2): permissions, then sign-in when the build needs it and the user
/// is signed out, then a test dictation with Start at login, applied only on Done.
public struct OnboardingFlow: Equatable {
    public enum Step: Equatable { case permissions, signIn, tryIt }
    public static let doneKey = "onboardingDone"

    public let steps: [Step]
    public private(set) var index = 0
    /// Ticked by default, as the .pkg turned it on.
    public var startAtLogin = true

    public init(signInNeeded: Bool) {
        steps = signInNeeded ? [.permissions, .signIn, .tryIt] : [.permissions, .tryIt]
    }

    /// At the first launch, and whenever Microphone, Accessibility or Input Monitoring is missing.
    public static func opensAtLaunch(done: Bool, requiredMissing: Bool) -> Bool { !done || requiredMissing }

    public var step: Step { steps[index] }
    public var isLast: Bool { index == steps.count - 1 }

    /// System Audio Recording is optional (meetings only), so it is not an argument: it never blocks.
    public func canContinue(requiredGranted: Bool, signedIn: Bool) -> Bool {
        switch step {
        case .permissions: requiredGranted
        case .signIn: signedIn
        case .tryIt: true  // the test is a check, not a gate
        }
    }

    public mutating func back() { index = max(0, index - 1) }

    /// Continue, or Done on the last step: then it returns whether to register Start at login. Closing the window
    /// instead changes nothing.
    public mutating func next(requiredGranted: Bool, signedIn: Bool) -> (registerLoginItem: Bool, done: Bool)? {
        guard canContinue(requiredGranted: requiredGranted, signedIn: signedIn) else { return nil }
        if isLast { return (startAtLogin, true) }
        index += 1
        return (false, false)
    }
}

/// Uninstall Shepetal… in Settings (docs/install-and-update.md 1). Everything goes to the Trash, so it can be undone.
public enum UninstallStep: Equatable {
    case unregisterLoginItem, restoreFnKey, signOut, resetPrivacy
    /// Stops Sparkle's installer that waits to put an update in place when the app quits.
    case cancelPendingUpdate
    /// Stops the crash watchdog (F99): with the data folder in the Trash it cannot see the clean quit and would
    /// treat the uninstall as a crash.
    case stopWatchdog
    case trash(URL)
    case deleteSettings
    case quit
}

public enum UninstallPlan {
    public static let bundleID = "io.backant.shepetal"

    /// Not for test and check builds (another bundle ID), and not while it runs from the DMG.
    public static func offered(bundleID: String, readOnlyVolume: Bool) -> Bool { bundleID == Self.bundleID && !readOnlyVolume }

    /// Why Uninstall is disabled right now, or nil.
    public static func blocker(_ a: Activity) -> String? {
        if a.meeting { return "Finish the meeting recording first" }
        if a.dictating { return "Finish the dictation first" }
        if a.retranscribing { return "Wait for the re-transcribe to finish" }
        return nil
    }

    /// The order matters: the login item needs the bundle in place, and the 🌐 key's old value lives in the settings,
    /// so both come before anything moves. `apps` are this bundle and every other Shepetal.app with our bundle ID.
    public static func steps(fnKeyRestorable: Bool, deleteData: Bool, model: URL, caches: URL, data: URL,
                             apps: [URL]) -> [UninstallStep] {
        var s: [UninstallStep] = [.unregisterLoginItem]
        if fnKeyRestorable { s.append(.restoreFnKey) }
        s += [.signOut, .resetPrivacy, .cancelPendingUpdate, .stopWatchdog, .trash(model), .trash(caches)]
        if deleteData { s += [.trash(data), .deleteSettings] }
        return s + apps.map(UninstallStep.trash) + [.quit]
    }
}

/// Move to Applications (docs/install-and-update.md 1): Sparkle cannot update a copy on the DMG or one macOS
/// translocated, so a copy run from there offers once to move itself.
public enum MovePrompt {
    public static let askedKey = "movePromptShown"

    public static func offers(path: String, home: String, readOnlyVolume: Bool, bundleID: String, asked: Bool) -> Bool {
        guard !asked, bundleID == UninstallPlan.bundleID else { return false }
        if path.contains("/AppTranslocation/") || readOnlyVolume { return true }
        if path.split(separator: "/").contains("Applications") { return false }  // /Applications, ~/Applications
        return path.hasPrefix("/Volumes/") || path.hasPrefix(home + "/Downloads/")
    }

    public enum Move: Equatable { case copy, replace, openInstalled }

    /// A newer copy already in Applications is opened, never replaced: moving must not downgrade.
    public static func move(installedBuild: Int?, runningBuild: Int) -> Move {
        guard let installed = installedBuild else { return .copy }
        return installed > runningBuild ? .openInstalled : .replace
    }
}
