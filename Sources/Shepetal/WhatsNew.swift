import AppKit
import ShepetalCore
import SwiftUI

/// What's new… on Home in the shepetal window: the release notes, newest first. Only that button opens it;
/// nothing opens at launch.
final class WhatsNewWindow: NSWindowController {
    /// In our own words, newest first, dates DD.MM.YY. The default VERSION in scripts/make-app.sh and
    /// scripts/make-dmg.sh must have an entry (WhatsNewNotesTests), so a version bump comes with its notes.
    static let notes: [(version: String, date: String, lines: [String])] = [
        ("0.1.0", "20.10.26", [
            "Hold fn to dictate. Your text appears where your cursor is. Double-tap fn for hands-free, then tap fn once to stop.",
            "Speech recognition runs on this Mac. Nothing you say leaves it.",
            "If the window you started in is no longer in front, the text stays on the clipboard instead of landing somewhere else.",
            "Every recording is kept as a WAV file. The last texts are under Recent in the shepetal menu in the menu bar, all of them under History in the shepetal window.",
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

    /// A "version · date" line per release in the mono label, then its lines in app-body: what the window says.
    static func text() -> NSAttributedString {
        let s = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: SH.appBody.nsFont, .foregroundColor: SH.text.nsColor]
        let heading: [NSAttributedString.Key: Any] = [.font: SH.label.nsFont, .foregroundColor: SH.textMuted.nsColor]
        for (n, note) in notes.enumerated() {
            s.append(NSAttributedString(string: (n > 0 ? "\n" : "") + "\(note.version) · \(note.date)\n", attributes: heading))
            for line in note.lines { s.append(NSAttributedString(string: "• \(line)\n", attributes: body)) }
        }
        return s
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "What's new in shepetal"
        window.isReleasedWhenClosed = false
        SmallWindow.style(window)
        window.contentView = NSHostingView(rootView: WhatsNewView())
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The notes on sh-bg, newest first: each release's version and date in mono, its lines in app-body.
private struct WhatsNewView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SmallWindowTitle("What's new in shepetal")
            ScrollView {
                VStack(alignment: .leading, spacing: SH.space6) {
                    ForEach(WhatsNewWindow.notes, id: \.version) { note in
                        VStack(alignment: .leading, spacing: SH.space3) {
                            Text("\(note.version) · \(note.date)").shText(SH.label).foregroundStyle(SH.textMuted)
                            ForEach(note.lines, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: SH.space2) {
                                    Text("•").accessibilityHidden(true)
                                    Text(line).fixedSize(horizontal: false, vertical: true)
                                }
                                .shText(SH.appBody)
                                .foregroundStyle(SH.text)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], SH.space5)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(SH.bg)
        .ignoresSafeArea(.container, edges: .top)  // the title sits in the title bar, beside the traffic lights
    }
}
