import AppKit
import QuartzCore
import ShepetalCore

/// The meeting reminder (design/ui/components/MeetingReminder): "Meeting detected · <app>" with Not now and Record,
/// just above 🤫, the one thing shepetal floats. 🤫 stays click-through, so the card is its own panel: it takes
/// clicks, but a borderless non-activating panel can never become key or activate Shepetal, so the app you are in
/// keeps focus. `MeetingOffer` decides when it shows and hides. It is a Night plate in both themes (it sits over any
/// wallpaper, like 🤫), with a hairline ring and the window's shadow for sh-pop; Record is the live signal keycap,
/// shown only while the call is starting. The update prompt is the same card with its own text and a primary
/// Install Now, one `row` higher, so it never covers Record.
@MainActor
final class MeetingCard: NSObject {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let label = NSTextField(labelWithString: "")
    let record = MeetingCardKey("Record", action: #selector(MeetingCard.recordClicked))
    let notNow = MeetingCardKey("Not now", action: #selector(MeetingCard.notNowClicked))
    /// The app on the card; nil while hidden.
    private(set) var app: String?
    private let screen: () -> NSRect
    private let present: (NSPanel) -> Void
    private let text: (String) -> String
    private let row: CGFloat
    private let onRecord: () -> Void
    private let onNotNow: () -> Void

    /// Like `Indicator`: tests pass a fixed display frame and a `present` that only counts, so nothing shows.
    /// `live`: the yes button is the signal keycap (a call is starting); false makes it the primary keycap.
    init(screen: @escaping () -> NSRect = { NSScreen.screens.first?.frame ?? .zero },
         present: @escaping (NSPanel) -> Void = { $0.orderFrontRegardless() },
         yes: String = "Record", no: String = "Not now", text: @escaping (String) -> String = { "Meeting detected · \($0)" },
         row: CGFloat = 0, live: Bool = true, onRecord: @escaping () -> Void, onNotNow: @escaping () -> Void) {
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
        panel.hasShadow = true  // sh-pop's cast shadow, drawn by the window server around the plate
        panel.appearance = NSAppearance(named: .darkAqua)  // the Night tokens, over any wallpaper

        label.font = SH.appStrong.nsFont
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        record.title = yes
        notNow.title = no
        record.variant = live ? .signal : .primary
        notNow.variant = .secondary
        for b in [record, notNow] {
            b.target = self
        }
        let stack = NSStackView(views: [label, notNow, record])
        stack.spacing = SH.space2
        stack.setCustomSpacing(SH.space4, after: label)
        stack.alignment = .centerY
        // 5 above and 3 below the 28 pt caps, whose 3 pt side fills the rest: the card stays under 40 pt.
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 3, right: 8)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = Self.plate
        stack.layer?.cornerRadius = SH.radiusSm
        stack.layer?.cornerCurve = .continuous
        stack.layer?.borderWidth = 1  // sh-pop's ring
        stack.layer?.borderColor = Self.ring
        panel.contentView = stack
    }

    /// sh-stone-900, Night's sh-bg: the plate stays dark under white text whatever the system is set to.
    private static let plate = CGColor(srgbRed: 0x16 / 255, green: 0x15 / 255, blue: 0x12 / 255, alpha: 1)

    /// sh-pop's 1 pt ring in Night: concrete at 12 %.
    private static let ring = CGColor(srgbRed: 0xE6 / 255, green: 0xE4 / 255, blue: 0xDE / 255, alpha: 0x1F / 255)

    /// "A new version of shepetal is ready. Install now?" for `SparkleUpdater`, one row above the meeting card. No
    /// `present` is `orderFrontRegardless()`, here on the main actor, where a default value would not be.
    static func update(screen: @escaping () -> NSRect = { NSScreen.screens.first?.frame ?? .zero },
                       present: ((NSPanel) -> Void)? = nil,
                       onInstall: @escaping () -> Void, onLater: @escaping () -> Void) -> MeetingCard {
        MeetingCard(screen: screen, present: present ?? { $0.orderFrontRegardless() }, yes: "Install Now", no: "Later",
                    text: { _ in UpdatePrompt.text }, row: 1, live: false, onRecord: onInstall, onNotNow: onLater)
    }

    /// Shows the card for `app`, or hides it for nil.
    func show(_ app: String?) {
        self.app = app
        guard let app else { return panel.orderOut(nil) }
        let shown = panel.isVisible
        label.stringValue = text(app)
        panel.setFrame(Self.frame(screen: screen(), size: panel.contentView?.fittingSize ?? .zero, row: row), display: true)
        present(panel)
        if !shown { enter() }
    }

    /// It enters 8 pt up and fades in over sh-dur-slow on sh-ease-settle; at once under Reduce motion. The panel
    /// stays where `frame` puts it: only the plate moves inside it.
    private func enter() {
        guard let layer = panel.contentView?.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let e = SH.easeSettle
        let timing = CAMediaTimingFunction(controlPoints: Float(e.x1), Float(e.y1), Float(e.x2), Float(e.y2))
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -8
        rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [rise, fade]
        group.duration = SH.durSlow
        group.timingFunction = timing
        layer.add(group, forKey: "sh-enter")
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

/// A keycap drawn for AppKit (design/ui/components/Button, sm): a 28 pt cap with a 3 pt side that goes down by its
/// travel while pressed. The card's panel is never key, so the buttons never take keyboard focus.
final class MeetingCardKey: NSButton {
    enum Variant { case primary, secondary, signal }

    var variant = Variant.secondary { didSet { needsDisplay = true } }

    private static let cap: CGFloat = SH.controlSm
    private static let side: CGFloat = 3
    private static let font = SH.appStrong.with(size: 13).nsFont

    convenience init(_ title: String, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.action = action
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryPushIn)
    }

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    /// Redraws the cap when tracking presses or lets go of it.
    private final class Cell: NSButtonCell {
        override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
            isHighlighted = flag
            controlView.needsDisplay = true
        }
    }

    override var title: String { didSet { invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(w) + 24, height: Self.cap + Self.side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        let travel: CGFloat = variant == .primary ? SH.travelPrimary : SH.travel
        let down = pressed ? travel : 0
        // The cap's rect, measured from the top of the button whichever way the view is flipped.
        func rect(top: CGFloat, height: CGFloat) -> NSRect {
            NSRect(x: 0, y: isFlipped ? top : bounds.height - top - height, width: bounds.width, height: height)
        }
        let side = NSBezierPath(roundedRect: rect(top: Self.side, height: Self.cap), xRadius: SH.radiusSm, yRadius: SH.radiusSm)
        let cap = rect(top: down, height: Self.cap)
        let face = NSBezierPath(roundedRect: cap, xRadius: SH.radiusSm, yRadius: SH.radiusSm)
        let (fill, edge, ink): (NSColor, NSColor, NSColor) = switch variant {
        case .primary: (SH.primaryFill.nsColor, SH.primarySide.nsColor, SH.onPrimary.nsColor)
        case .secondary: (SH.keyFill.nsColor, SH.keySide.nsColor, SH.text.nsColor)
        case .signal: (pressed ? SH.signal600.nsColor : SH.signal.nsColor, SH.signal700.nsColor, SH.onSignal.nsColor)
        }
        edge.setFill()
        side.fill()
        fill.setFill()
        face.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ink]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2), withAttributes: attributes)
    }
}
