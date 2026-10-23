import AppKit
import ShepetalCore

/// The indicator (design/ui/components/Indicator): the Noto 🤫 artwork, sh-indicator (18 pt), sh-space-2 (8 pt) in
/// from the bottom-left corner of the main display's work area (above the Dock when it sits at the bottom), on every
/// Space and over full-screen apps, click-through, never takes focus, always shown. Its ring says what shepetal is
/// doing: recording a full signal ring, hands-free a signal ring with a gap at the top, writing an ink ring that
/// pulses. A note has no ring, only a short label next to it. The state is named in words for accessibility.
final class Indicator {
    enum Mode: Equatable { case idle, recording, handsFree, processing, error }

    /// What the ring shows (design/ui README, The indicator states). A note is the label, so it has no ring.
    enum Ring: Equatable { case none, recording, handsFree, writing }

    static let size: CGFloat = SH.indicator
    static let inset: CGFloat = SH.space2

    let panel = IndicatorPanel(contentRect: NSRect(x: 0, y: 0, width: Indicator.size, height: Indicator.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let emoji = IndicatorArtwork(frame: NSRect(x: 0, y: 0, width: Indicator.size, height: Indicator.size))  // carries the ring
    private let label = NoteLabel()
    private var labelUntil: DispatchWorkItem?
    private let screen: () -> NSRect

    /// `screen` is the main display's work area (it holds the menu bar; `.zero` when headless). `present` puts the
    /// panel on screen once; tests pass a fixed frame and a `present` that only counts, so nothing shows.
    init(screen: @escaping () -> NSRect = { NSScreen.screens.first?.visibleFrame ?? .zero },
         present: (NSPanel) -> Void = { $0.orderFrontRegardless() }) {
        self.screen = screen
        panel.level = .statusBar  // above the Dock
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        view.addSubview(emoji)

        label.isHidden = true
        view.addSubview(label)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }
        set(.idle)
        layout()
        present(panel)
    }

    private(set) var mode: Mode = .idle
    /// True while a meeting records: the ring shows Recording the whole time, whatever dictation does meanwhile.
    var meeting = false { didSet { set(mode) } }

    func set(_ mode: Mode) {
        self.mode = mode
        if mode != .recording && mode != .handsFree { status = nil }  // never outlives the dictation
        let ring: Ring = switch mode {
        case .idle, .error: .none  // an error is a note: the label next to the indicator says it
        case .recording: .recording
        case .handsFree: .handsFree
        case .processing: .writing
        }
        emoji.ring = meeting ? .recording : ring
        emoji.setAccessibilityLabel(stateName)
    }

    /// The state in words, as VoiceOver reads it: Recording, Hands-free, Writing, A note, or Ready.
    var stateName: String {
        switch emoji.ring {
        case .recording: "Recording"
        case .handsFree: "Hands-free"
        case .writing: "Writing"
        case .none: mode == .error || labelText != nil ? "A note" : "Ready"
        }
    }

    /// Everything `show` put next to 🤫, for the Hub's Recent notices (F100).
    private(set) var notices = NoticeLog()

    /// Text next to the indicator for `seconds`, e.g. the short-press hint. It covers `status`, which comes back after.
    /// It is also kept in `notices`, except a 0 s show, which only clears the label (SecureInput does this), so the
    /// notice keeps the time it showed. `status` goes through setLabel, not here, so it stays out of the log.
    func show(_ text: String, seconds: TimeInterval) {
        if seconds > 0 { notices.append(text) }
        labelUntil?.cancel()
        setLabel(text)
        let end = DispatchWorkItem { [weak self] in
            self?.labelUntil = nil
            self?.setLabel(self?.status)
        }
        labelUntil = end
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: end)
    }

    /// Text that stays next to the indicator while set and while recording, e.g. creator mode's label.
    /// A hint covers it for its seconds. Any mode other than recording or hands-free clears it, and it cannot be
    /// set outside them, so live words (F13) that come back after the release never show.
    var status: String? {
        didSet {
            if mode != .recording && mode != .handsFree { status = nil }
            if labelUntil == nil, status != oldValue { setLabel(status) }
        }
    }

    /// "Creator mode" in Settings: the label shows while recording, for screen recordings. Unset means off.
    static let creatorModeKey = "creatorMode"
    static let creatorLabel = "Dictating with shepetal"
    /// The `status` to set when recording starts: the creator label, or nil when the setting is off.
    static func creatorStatus(_ defaults: UserDefaults = .standard) -> String? {
        defaults.bool(forKey: creatorModeKey) ? creatorLabel : nil
    }
    /// The `status` for live words (F13): after the creator label when creator mode is on, so viewers still see it
    /// for the whole recording.
    static func liveStatus(_ words: String, _ defaults: UserDefaults = .standard) -> String {
        creatorStatus(defaults).map { "\($0) · \(words)" } ?? words
    }

    private func setLabel(_ text: String?) {
        label.stringValue = text ?? ""
        label.isHidden = text == nil
        emoji.setAccessibilityLabel(stateName)
        layout()
    }

    var labelText: String? { label.isHidden ? nil : label.stringValue.trimmingCharacters(in: .whitespaces) }

    /// The panel's frame on `screen`: the 18 pt indicator 8 pt in from the bottom-left corner, plus the label
    /// to its right when one shows. The panel grows rightward only, so the indicator never moves.
    static func frame(screen: NSRect, labelWidth: CGFloat?) -> NSRect {
        NSRect(x: screen.minX + inset, y: screen.minY + inset,
               width: labelWidth.map { size + labelGap + $0 } ?? size, height: size)
    }

    static let labelGap: CGFloat = 6

    private func layout() {
        var labelWidth: CGFloat?
        if !label.isHidden {
            label.sizeToFit()
            label.frame.size.height = min(label.frame.height, Self.size)
            label.frame.origin = NSPoint(x: Self.size + Self.labelGap, y: (Self.size - label.frame.height) / 2)
            labelWidth = label.frame.width
        }
        panel.setFrame(Self.frame(screen: screen(), labelWidth: labelWidth), display: true)
    }
}

/// Counts `orderOut`, so tests can check that 🤫 is never hidden without putting it on screen.
final class IndicatorPanel: NSPanel {
    private(set) var orderedOut = 0

    override func orderOut(_ sender: Any?) {
        orderedOut += 1
        super.orderOut(sender)
    }
}

/// The Noto 🤫 (never a typed emoji), 12 pt in its 18 pt square, under the ring.
final class IndicatorArtwork: NSView {
    let ringView = IndicatorRing(frame: NSRect(x: 0, y: 0, width: Indicator.size, height: Indicator.size))

    var ring: Indicator.Ring {
        get { ringView.ring }
        set { ringView.ring = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ringView.autoresizingMask = [.width, .height]
        addSubview(ringView)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 12
        SHIndicator.shush.draw(in: NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side))
    }
}

/// The ring, drawn in the state's token for the appearance it is shown in. Its color changes in sh-dur-fast; the
/// writing ring breathes from 100 % to 35 %, sh-dur-pulse each way, and rests at full under Reduce motion.
final class IndicatorRing: NSView {
    static let width: CGFloat = 2

    var ring: Indicator.Ring = .none {
        didSet {
            guard ring != oldValue else { return }
            if !reduceMotion {
                let fade = CATransition()
                fade.duration = SH.durFast
                fade.timingFunction = CAMediaTimingFunction(controlPoints: Float(SH.easeSettle.x1), Float(SH.easeSettle.y1),
                                                            Float(SH.easeSettle.x2), Float(SH.easeSettle.y2))
                layer?.add(fade, forKey: kCATransition)
            }
            needsDisplay = true
            pulse()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// sh-state-recording, sh-state-hands-free (both signal) or sh-state-writing (ink); nil for no ring.
    static func color(_ ring: Indicator.Ring) -> SHColor? {
        switch ring {
        case .none: nil
        case .recording: SH.stateRecording
        case .handsFree: SH.stateHandsFree
        case .writing: SH.stateWriting
        }
    }

    /// The ring inside `bounds`: a full circle, or for hands-free a circle with a 40 degree gap centred on the top
    /// (bundle.css masks the ring from 340 to 20 degrees). The view is not flipped, so the top is 90 degrees.
    static func path(_ ring: Indicator.Ring, in bounds: NSRect) -> NSBezierPath? {
        guard ring != .none else { return nil }
        let r = min(bounds.width, bounds.height) / 2 - width / 2
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = NSBezierPath()
        if ring == .handsFree {
            path.appendArc(withCenter: center, radius: r, startAngle: 110, endAngle: 70, clockwise: false)
        } else {
            path.appendOval(in: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }
        path.lineWidth = width
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let path = Self.path(ring, in: bounds), let color = Self.color(ring) else { return }
        color.nsColor.setStroke()
        path.stroke()
    }

    private func pulse() {
        layer?.removeAnimation(forKey: "pulse")
        guard ring == .writing, !reduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = SH.durPulse
        pulse.timingFunction = CAMediaTimingFunction(controlPoints: Float(SH.easeBreathe.x1), Float(SH.easeBreathe.y1),
                                                     Float(SH.easeBreathe.x2), Float(SH.easeBreathe.y2))
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "pulse")
    }
}

/// A note's label (sh-indicator-label): Archivo 11 at 560 in sh-note-text on sh-note-label, 4 pt corners, dark in
/// both themes so it reads on any wallpaper.
private final class NoteLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        cell = NoteCell(textCell: "")
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        lineBreakMode = .byClipping
        font = SHFonts.ctFont(.ui, size: 11, weight: 560) as NSFont
        textColor = .white  // sh-note-text is white in Concrete and Night
        wantsLayer = true
        layer?.backgroundColor = SH.noteLabel.nsColor.cgColor  // black at 75 % in both themes
        layer?.cornerRadius = SH.radiusSm
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 8 pt either side of the text and 2 pt above and below, as the label's padding.
private final class NoteCell: NSTextFieldCell {
    static let pad = NSSize(width: 8, height: 2)

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let s = super.cellSize(forBounds: rect)
        return NSSize(width: s.width + 2 * Self.pad.width, height: s.height + 2 * Self.pad.height)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: Self.pad.width, dy: Self.pad.height))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect.insetBy(dx: Self.pad.width, dy: Self.pad.height))
    }
}
