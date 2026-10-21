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

    var why: String {
        switch self {
        case .microphone: "to hear you while fn is held"
        case .inputMonitoring: "to notice the fn key"
        case .accessibility: "to paste the text where your cursor is"
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Shepetal"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        model.close = { [weak window] in window?.close() }
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
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

    func next() {
        guard let r = flow.next(requiredGranted: requiredGranted, signedIn: Account.shared.signedIn), r.done else { return }
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

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var account = Account.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in  // live permission status
            VStack(alignment: .leading, spacing: 0) {
                Form { step }.formStyle(.grouped)
                HStack {
                    if model.flow.index > 0 { Button("Back") { model.flow.back() } }
                    Spacer()
                    Button(model.flow.isLast ? "Done" : "Continue", action: model.next)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.flow.canContinue(requiredGranted: model.requiredGranted, signedIn: account.signedIn))
                }
                .padding([.horizontal, .bottom])
            }
        }
        .frame(width: 520)
    }

    @ViewBuilder private var step: some View {
        switch model.flow.step {
        case .permissions:
            Section("Shepetal runs on this Mac only. It needs these permissions:") {
                ForEach(Permission.allCases, id: \.self) { p in
                    row(p.granted, p.title, p.why) { model.grant(p) }
                }
                let audio = SystemMeetingCapture.systemAudioStatus()
                row(audio == 0, "System Audio Recording (optional)", "to record the other people in a meeting") {
                    NSWorkspace.shared.open(OnboardingModel.systemAudioPane)
                }
            }
        case .signIn:
            AccountSection()
        case .tryIt:
            let engine = model.engine()
            Section("Try it") {
                if !engine.ready { Text(engine.status).foregroundStyle(.secondary) }
                TextField("Click here, hold fn and say something.", text: $model.tried, axis: .vertical)
                    .lineLimit(3...5).disabled(!engine.ready)
                if !model.tried.isEmpty { Text("✅ It works") }
                Toggle("Start Shepetal when I log in", isOn: $model.flow.startAtLogin)
            }
        }
    }

    private func row(_ granted: Bool, _ title: String, _ why: String, open: @escaping () -> Void) -> some View {
        HStack {
            Text("\(granted ? "✅" : "⚠️") \(title): \(why)")
            Spacer()
            if !granted { Button("Open", action: open) }
        }
    }
}

/// Notices a permission that was turned off while Shepetal runs, and all of them back on: on the 2 s timer,
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
