import AppKit
import ShepetalCore

/// What's new… on Home in the shepetal window: the release notes, newest first. Only that button opens it;
/// nothing opens at launch.
final class WhatsNewWindow: NSWindowController {
    /// In our own words, newest first, dates DD.MM.YY. The default VERSION in scripts/make-app.sh and
    /// scripts/make-dmg.sh must have an entry (WhatsNewNotesTests), so a version bump comes with its notes.
    static let notes: [(version: String, date: String, lines: [String])] = [
        ("0.1.0", "20.10.26", [
            "Hold fn and talk: the text is typed where your cursor is. Double-tap fn for hands-free, then tap fn once to stop.",
            "Speech recognition runs on this Mac. Nothing you say leaves it.",
            "If the window you started in is no longer in front, the text stays on the clipboard instead of landing somewhere else.",
            "Every recording is kept as a WAV file. The last texts are under Recent in the 🤫 menu, all of them under History in the shepetal window.",
            "The installer sets the 🌐 key to Do Nothing, so fn can dictate, and turns on Start at login.",
        ]),
    ]

    /// This build's version. nil without the app bundle (swift run, tests), so nothing is announced or recorded.
    static var current: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    /// The version to announce after an update, once. Call it before Pipeline creates history.sqlite:
    /// that file already being there is how an update from 0.1.0 is told from a first install.
    static func atLaunch() -> String? {
        guard let current else { return nil }
        let hadData = FileManager.default.fileExists(atPath: Paths.root.appendingPathComponent("history.sqlite").path)
        return WhatsNew.launch(current: current, hadData: hadData)
    }

    /// A bold "version · date" heading per release, then its lines.
    static func text() -> NSAttributedString {
        let s = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        var heading = body
        heading[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold)
        for (n, note) in notes.enumerated() {
            s.append(NSAttributedString(string: (n > 0 ? "\n" : "") + "\(note.version) · \(note.date)\n", attributes: heading))
            for line in note.lines { s.append(NSAttributedString(string: "• \(line)\n", attributes: body)) }
        }
        return s
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "What's new in shepetal"
        window.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.textContainerInset = NSSize(width: 12, height: 12)
            view.textStorage?.setAttributedString(Self.text())
        }
        window.contentView = scroll
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}
