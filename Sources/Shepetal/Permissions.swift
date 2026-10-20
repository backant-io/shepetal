import AppKit
import AVFoundation

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

/// One window, one row per permission: its state, why it is needed, and a button that asks
/// (unless prompts are off) and opens the matching System Settings pane.
final class Onboarding: NSWindowController {
    private let allowRequests: Bool
    private var rows: [(Permission, NSTextField)] = []
    private var timer: Timer?

    init(allowRequests: Bool) {
        self.allowRequests = allowRequests
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Shepetal permissions"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let intro = NSTextField(wrappingLabelWithString: "Shepetal runs on this Mac only. It needs three permissions:")
        stack.addArrangedSubview(intro)
        for p in Permission.allCases {
            let label = NSTextField(labelWithString: "")
            let button = NSButton(title: "Grant…", target: self, action: #selector(grant(_:)))
            button.tag = Permission.allCases.firstIndex(of: p)!
            let row = NSStackView(views: [label, NSView(), button])
            row.widthAnchor.constraint(equalToConstant: 428).isActive = true
            stack.addArrangedSubview(row)
            rows.append((p, label))
        }
        window.contentView = stack
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    func refresh() {
        for (p, label) in rows {
            label.stringValue = "\(p.granted ? "✅" : "⚠️") \(p.title): \(p.why)"
        }
    }

    @objc private func grant(_ sender: NSButton) {
        let p = Permission.allCases[sender.tag]
        let firstMicAsk = p == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        if allowRequests { p.request() }
        if !(allowRequests && firstMicAsk) { NSWorkspace.shared.open(p.settingsURL) }
    }
}
