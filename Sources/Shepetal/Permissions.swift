import AppKit
import AVFoundation
import ShepetalCore
import SwiftUI

enum Permission: CaseIterable {
    case microphone, inputMonitoring, accessibility

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        }
    }

    /// Why, in one sentence that names the setting as macOS shows it (design/ui 01-platforms, Words for the system).
    var why: String {
        switch self {
        case .microphone: "Microphone lets shepetal hear you while you hold fn."
        case .inputMonitoring: "Input Monitoring lets shepetal notice when you press fn."
        case .accessibility: "Accessibility lets shepetal paste your text where your cursor is."
        }
    }

    /// Checks only; never shows a system prompt.
    var granted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring: CGPreflightListenEventAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }

    var settingsURL: URL {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// Shows the macOS prompt where there is one. Never called under --no-permission-prompts.
    func request() {
        switch self {
        case .microphone: AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        case .accessibility: _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
    }

    static var missing: [Permission] { allCases.filter { !$0.granted } }
}

/// The first-run window (docs/install-and-update.md 2, `OnboardingFlow`): the permissions with live status, sign-in
/// when the build needs it, then a test dictation and Start at login. It opens at the first launch and whenever a
/// required permission is missing; Permissions… and Permissions needed… open it at step 1.
@MainActor
final class Onboarding: NSWindowController {
    private let model: OnboardingModel

    init(allowRequests: Bool, engine: @escaping () -> (ready: Bool, status: String), loginItem: LoginItem) {
        model = OnboardingModel(allowRequests: allowRequests, engine: engine, loginItem: loginItem)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to shepetal"
        window.isReleasedWhenClosed = false
        SmallWindow.style(window)
        super.init(window: window)
        model.close = { [weak window] in window?.close() }
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        // Closed is seen: it opens again at launch only while a required permission is missing, never at every
        // login. Start at login still waits for Done.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            UserDefaults.standard.set(true, forKey: OnboardingFlow.doneKey)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Back to step 1, with the sign-in step only while it is needed.
    func restart() {
        model.flow = OnboardingFlow(signInNeeded: Account.signInRequired() && !Account.shared.signedIn)
        model.tried = ""
    }

    static var done: Bool { UserDefaults.standard.bool(forKey: OnboardingFlow.doneKey) }
}

@MainActor
final class OnboardingModel: ObservableObject {
    let allowRequests: Bool
    let engine: () -> (ready: Bool, status: String)
    let loginItem: LoginItem
    var close: () -> Void = {}
    @Published var flow = OnboardingFlow(signInNeeded: false)
    @Published var tried = ""

    init(allowRequests: Bool, engine: @escaping () -> (ready: Bool, status: String), loginItem: LoginItem) {
        self.allowRequests = allowRequests; self.engine = engine; self.loginItem = loginItem
    }

    var requiredGranted: Bool { Permission.missing.isEmpty }
    /// Read only on the sign-in step, so the window (and its test) never touches the account before then.
    var signedIn: Bool { flow.step == .signIn && Account.shared.signedIn }

    func next() {
        guard let r = flow.next(requiredGranted: requiredGranted, signedIn: signedIn), r.done else { return }
        if r.registerLoginItem, !loginItem.isOn { loginItem.toggle() }
        UserDefaults.standard.set(true, forKey: OnboardingFlow.doneKey)
        close()
    }

    /// The first click asks macOS, so the app is listed in the pane, then the pane opens.
    func grant(_ p: Permission) {
        let firstMicAsk = p == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        if allowRequests { p.request() }
        if !(allowRequests && firstMicAsk) { NSWorkspace.shared.open(p.settingsURL) }
    }

    /// System Audio Recording, for meetings only. macOS asks at the first meeting recording.
    static let systemAudioPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// One step at a time on sh-bg: the step in mono, its title, its rows, and one primary keycap (sh-control-lg) that
/// moves on. Permission rows say why in one sentence and open the setting; the fn key is a key hint.
private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in  // live permission status
            VStack(alignment: .leading, spacing: 0) {
                SmallWindowTitle("Welcome to shepetal")
                VStack(alignment: .leading, spacing: SH.space5) {
                    VStack(alignment: .leading, spacing: SH.space2) {
                        Text("Step \(model.flow.index + 1) of \(model.flow.steps.count)").shText(SH.label).foregroundStyle(SH.textMuted)
                        Text(title).shText(SH.appTitle).foregroundStyle(SH.text)
                        if let lead { Text(lead).shText(SH.appBody).foregroundStyle(SH.textMuted).fixedSize(horizontal: false, vertical: true) }
                    }
                    step
                }
                .padding(.horizontal, SH.space5)
                .padding(.top, SH.space2)
                HStack(spacing: SH.space3) {
                    if model.flow.index > 0 { Button("Back") { model.flow.back() }.buttonStyle(.keycap(.secondary, .lg)) }
                    Spacer()
                    Button(model.flow.isLast ? "Done" : "Continue", action: model.next)
                        .buttonStyle(.keycap(.primary, .lg))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.flow.canContinue(requiredGranted: model.requiredGranted, signedIn: model.signedIn))
                }
                .padding(SH.space5)
            }
        }
        .frame(width: 560)
        .background(SH.bg)
    }

    private var title: String {
        switch model.flow.step {
        case .permissions: "Permissions"
        case .signIn: "Account"
        case .tryIt: "Try it"
        }
    }

    private var lead: String? {
        model.flow.step == .permissions ? "shepetal runs on this Mac only. It needs these permissions." : nil
    }

    @ViewBuilder private var step: some View {
        switch model.flow.step {
        case .permissions:
            SHRows {
                ForEach(Permission.allCases, id: \.self) { p in
                    row(p.granted, "Required", p.title, p.why) { model.grant(p) }
                }
                let audio = SystemMeetingCapture.systemAudioStatus()
                row(audio == 0, "Optional", "System Audio Recording",
                    "System Audio Recording lets shepetal record the other people in a meeting.") {
                    NSWorkspace.shared.open(OnboardingModel.systemAudioPane)
                }
            }
        case .signIn:
            VStack(alignment: .leading, spacing: SH.space3) { AccountSection() }
        case .tryIt:
            let engine = model.engine()
            VStack(alignment: .leading, spacing: SH.space4) {
                if !engine.ready { Text(engine.status).shText(SH.appSmall).foregroundStyle(SH.textMuted) }
                HStack(spacing: 6) {
                    Text("Click in the field below, hold").shText(SH.appBody)
                    SHKbd("fn")
                    Text("and say something.").shText(SH.appBody)
                }
                .foregroundStyle(SH.text)
                .accessibilityElement(children: .combine)
                TextField("Your words appear here.", text: $model.tried, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.shField)
                    .disabled(!engine.ready)
                    .accessibilityLabel("Try it")
                if !model.tried.isEmpty {
                    HStack(spacing: SH.space2) {
                        SHIcon(.check)
                        Text("It works").shText(SH.appStrong)
                    }
                    .foregroundStyle(SH.text)
                    .accessibilityElement(children: .combine)
                }
                Toggle("Start shepetal when I log in", isOn: $model.flow.startAtLogin).toggleStyle(.shSwitch)
            }
        }
    }

    /// The setting, why in one sentence, and Open settings while it is off; a check and Allowed once it is on.
    private func row(_ granted: Bool, _ label: String, _ title: String, _ why: String, open: @escaping () -> Void) -> some View {
        SHRow(label, title: title, help: why) {
            if granted {
                HStack(spacing: 6) {
                    SHIcon(.check)
                    Text("Allowed").shText(SH.appSmall)
                }
                .foregroundStyle(SH.textMuted)
                .accessibilityElement(children: .combine)
            } else {
                Button("Open settings", action: open)
                    .buttonStyle(.keycap(.secondary))
                    .accessibilityLabel("Open settings for \(title)")
            }
        }
    }
}

/// Notices a permission that was turned off while shepetal runs, and all of them back on: on the 2 s timer,
/// after wake, and whenever an app comes to the front (the user coming back from System Settings).
@MainActor
final class PermissionMonitor {
    private var watch = PermissionWatch<Permission>()
    private let revoked: (String) -> Void
    private let restored: () -> Void

    /// `revoked` gets the message to show, for example "Accessibility access was turned off". `restored` runs
    /// once every permission is back on after a revocation.
    init(revoked: @escaping (String) -> Void, restored: @escaping () -> Void) {
        self.revoked = revoked
        self.restored = restored
        check()  // the first poll only records
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    func check() {
        for p in watch.observe(Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.granted) })) {
            revoked(PermissionWatch<Permission>.message(p.title))
        }
        if watch.restored { restored() }
    }
}
