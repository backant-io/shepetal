import AppKit
import ShepetalCore

/// One row per action: its chord and a Change… button that records the next chord through the tap.
/// A refused chord shows why. Reset puts the defaults back. Bindings live in UserDefaults ("shortcuts").
final class ShortcutsWindow: NSWindowController, NSWindowDelegate {
    private static let defaultsKey = "shortcuts"
    static var saved: Shortcuts { Shortcuts(stored: UserDefaults.standard.dictionary(forKey: defaultsKey)) }

    private let tap: FnTap
    private var chords: [ShortcutAction: NSTextField] = [:]
    private var buttons: [ShortcutAction: NSButton] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private var recording: ShortcutAction?

    init(tap: FnTap) {
        self.tap = tap
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 325),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Shepetal shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for (i, action) in ShortcutAction.allCases.enumerated() {
            let chord = NSTextField(labelWithString: "")
            chord.font = .systemFont(ofSize: 13, weight: .semibold)
            let button = NSButton(title: "Change…", target: self, action: #selector(change(_:)))
            button.tag = i
            let title = NSTextField(labelWithString: action.title)
            title.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let row = NSStackView(views: [title, chord, NSView(), button])
            row.widthAnchor.constraint(equalToConstant: 408).isActive = true
            stack.addArrangedSubview(row)
            chords[action] = chord
            buttons[action] = button
        }
        status.textColor = .systemRed
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetDefaults))
        for v in [status, note, reset] { stack.addArrangedSubview(v) }
        for v in [status, note] { v.preferredMaxLayoutWidth = 408 }
        window.contentView = stack
        let refused = tap.router.shortcuts.refused
        if !refused.isEmpty {
            status.stringValue = "Saved keys for \(refused.map(\.title).joined(separator: ", ")) were not allowed, so the default is back."
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The chord the tap recorded for the row that asked.
    func recorded(_ raw: Set<Int>) {
        guard let action = recording else { return }
        recording = nil
        if let problem = tap.updateRouter({ $0.shortcuts.set(raw, for: action) }) {
            status.stringValue = "\(Key.label(raw)): \(problem.message)"
        } else {
            status.stringValue = ""
            save()
        }
        refresh()
    }

    func windowWillClose(_ notification: Notification) { stopRecording() }

    /// Leaving the window (⌘Tab included) ends the recording, so its keys reach the next app again.
    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    private func stopRecording() {
        guard recording != nil else { return }
        recording = nil
        tap.updateRouter { $0.stopRecording() }
        refresh()
    }

    @objc private func change(_ sender: NSButton) {
        recording = ShortcutAction.allCases[sender.tag]
        status.stringValue = ""
        tap.updateRouter { $0.record() }
        refresh()
    }

    @objc private func resetDefaults() {
        recording = nil
        tap.updateRouter { $0.stopRecording(); $0.shortcuts.reset() }
        status.stringValue = ""
        save()
        refresh()
    }

    private func save() { UserDefaults.standard.set(tap.router.shortcuts.stored, forKey: Self.defaultsKey) }

    private func refresh() {
        for action in ShortcutAction.allCases {
            let isRecording = recording == action
            chords[action]?.stringValue = isRecording ? "Press the keys…" : Key.label(tap.router.shortcuts.chord(action))
            buttons[action]?.isEnabled = recording == nil || isRecording
        }
        if !tap.isRunning {
            note.stringValue = "Shortcuts need Input Monitoring. Open Settings > Permissions… in the shepetal window."
        } else if !tap.canSwallow {
            note.stringValue = "Without Accessibility, Esc and the keys of a shortcut also reach the app you are typing in."
        } else {
            let cancel = Key.label(tap.router.shortcuts.chord(.dismiss))
            note.stringValue = "\(cancel) cancels only while Shepetal is listening or transcribing. Otherwise it reaches your app."
        }
    }
}
