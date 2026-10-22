import AppKit
import ShepetalCore

/// "Meeting detected · <app>" with Record and Not now, just above 🤫. 🤫 stays click-through, so the card is its
/// own panel: it takes clicks, but a borderless non-activating panel can never become key or activate Shepetal,
/// so the app you are in keeps focus. `MeetingOffer` decides when it shows and hides. The update prompt is the same
/// card with its own text and buttons, one `row` higher, so it never covers Record.
@MainActor
final class MeetingCard: NSObject {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let label = NSTextField(labelWithString: "")
    let record = NSButton(title: "Record", target: nil, action: #selector(MeetingCard.recordClicked))
    let notNow = NSButton(title: "Not now", target: nil, action: #selector(MeetingCard.notNowClicked))
    /// The app on the card; nil while hidden.
    private(set) var app: String?
    private let screen: () -> NSRect
    private let present: (NSPanel) -> Void
    private let text: (String) -> String
    private let row: CGFloat
    private let onRecord: () -> Void
    private let onNotNow: () -> Void

    /// Like `Indicator`: tests pass a fixed display frame and a `present` that only counts, so nothing shows.
    init(screen: @escaping () -> NSRect = { NSScreen.screens.first?.frame ?? .zero },
         present: @escaping (NSPanel) -> Void = { $0.orderFrontRegardless() },
         yes: String = "Record", no: String = "Not now", text: @escaping (String) -> String = { "Meeting detected · \($0)" },
         row: CGFloat = 0, onRecord: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.screen = screen
        self.present = present
        self.text = text
        self.row = row
        self.onRecord = onRecord
        self.onNotNow = onNotNow
        super.init()
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false  // an accessory app is never active
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        record.title = yes
        notNow.title = no
        for b in [record, notNow] {
            b.target = self
            b.controlSize = .small
        }
        let stack = NSStackView(views: [label, record, notNow])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)  // room for the buttons' bezels
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        stack.layer?.cornerRadius = 6
        panel.contentView = stack
    }

    /// "A new version of shepetal is ready. Install now?" for `SparkleUpdater`, one row above the meeting card.
    static func update(screen: @escaping () -> NSRect = { NSScreen.screens.first?.frame ?? .zero },
                       present: @escaping (NSPanel) -> Void = { $0.orderFrontRegardless() },
                       onInstall: @escaping () -> Void, onLater: @escaping () -> Void) -> MeetingCard {
        MeetingCard(screen: screen, present: present, yes: "Install Now", no: "Later", text: { _ in UpdatePrompt.text },
                    row: 1, onRecord: onInstall, onNotNow: onLater)
    }

    /// Shows the card for `app`, or hides it for nil.
    func show(_ app: String?) {
        self.app = app
        guard let app else { return panel.orderOut(nil) }
        label.stringValue = text(app)
        panel.setFrame(Self.frame(screen: screen(), size: panel.contentView?.fittingSize ?? .zero, row: row), display: true)
        present(panel)
    }

    /// Just above 🤫 with the left edges aligned, so the hint text next to 🤫 never hides under it. Each `row` is one
    /// card higher.
    static func frame(screen: NSRect, size: NSSize, row: CGFloat = 0) -> NSRect {
        NSRect(origin: NSPoint(x: screen.minX + Indicator.inset,
                               y: screen.minY + Indicator.inset + Indicator.size + Indicator.labelGap
                                   + row * (size.height + Indicator.labelGap)), size: size)
    }

    @objc private func recordClicked() { onRecord() }
    @objc private func notNowClicked() { onNotNow() }
}
