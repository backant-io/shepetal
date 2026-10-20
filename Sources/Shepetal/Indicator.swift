import AppKit

/// The 🤫 indicator: about 18 pt, 8 pt in from the bottom-left corner of the main display,
/// on every Space and over full-screen apps, click-through, never takes focus, always shown.
/// States show as a ring around it; hints and errors as short text next to it.
final class Indicator {
    enum Mode: Equatable { case idle, recording, handsFree, processing, error }

    static let size: CGFloat = 18
    static let inset: CGFloat = 8

    let panel: NSPanel
    let emoji: NSView = EmojiView(frame: NSRect(x: 0, y: 0, width: Indicator.size, height: Indicator.size))  // carries the ring
    private let label = NSTextField(labelWithString: "")
    private var labelUntil: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

        emoji.wantsLayer = true
        emoji.layer?.cornerRadius = Self.size / 2
        view.addSubview(emoji)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        label.layer?.cornerRadius = 4
        label.isHidden = true
        view.addSubview(label)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }
        layout()
        panel.orderFrontRegardless()
    }

    private(set) var mode: Mode = .idle

    func set(_ mode: Mode) {
        self.mode = mode
        let ring: NSColor? = switch mode {
        case .idle: nil
        case .recording: .systemRed
        case .handsFree: .systemOrange
        case .processing: .systemBlue
        case .error: .systemYellow
        }
        emoji.layer?.borderWidth = ring == nil ? 0 : 2
        emoji.layer?.borderColor = ring?.cgColor
        emoji.layer?.removeAllAnimations()
        if mode == .processing {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            emoji.layer?.add(pulse, forKey: "pulse")
        }
    }

    /// Text next to the indicator for `seconds`, e.g. the short-press hint.
    func show(_ text: String, seconds: TimeInterval) {
        labelUntil?.cancel()
        label.stringValue = " \(text) "
        label.isHidden = false
        layout()
        let hide = DispatchWorkItem { [weak self] in
            self?.label.isHidden = true
            self?.layout()
        }
        labelUntil = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: hide)
    }

    var labelText: String? { label.isHidden ? nil : label.stringValue.trimmingCharacters(in: .whitespaces) }

    /// The panel's frame on `screen`: the 18 pt emoji 8 pt in from the bottom-left corner, plus the label
    /// to its right when one shows. The panel grows rightward only, so the emoji never moves.
    static func frame(screen: NSRect, labelWidth: CGFloat?) -> NSRect {
        NSRect(x: screen.minX + inset, y: screen.minY + inset,
               width: labelWidth.map { size + labelGap + $0 } ?? size, height: size)
    }

    static let labelGap: CGFloat = 6

    private func layout() {
        // The main display holds the menu bar. With no display (headless), the frame still updates.
        let screen = NSScreen.screens.first?.frame ?? .zero
        var labelWidth: CGFloat?
        if !label.isHidden {
            label.sizeToFit()
            label.frame.origin = NSPoint(x: Self.size + Self.labelGap, y: (Self.size - label.frame.height) / 2)
            labelWidth = label.frame.width
        }
        panel.setFrame(Self.frame(screen: screen, labelWidth: labelWidth), display: true)
    }
}

/// The emoji drawn centered in its 18 pt square (a text field pads and clips it).
private final class EmojiView: NSView {
    private let glyph = NSAttributedString(string: "🤫", attributes: [.font: NSFont.systemFont(ofSize: 13)])

    override func draw(_ dirtyRect: NSRect) {
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
