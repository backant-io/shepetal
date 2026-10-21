import AppKit
import ShepetalCore
import SwiftUI
import UniformTypeIdentifiers

/// F118: your words, words per minute and streak as an image card. It is made here, and Copy, Save… and Post act
/// only on their click. Nothing is uploaded: Post opens a prefilled post in the browser, and the user sends it.
struct ShareStats: Equatable, Identifiable {
    var words: Int
    var wpm: Int
    var streak: Int

    var id: [Int] { [words, wpm, streak] }

    init(words: Int, wpm: Int, streak: Int) { self.words = words; self.wpm = wpm; self.streak = streak }

    /// All-time words and words per minute (Your stats) and the streak (Insights), over delivered dictations.
    init(_ history: History, today: Date = Date()) throws {
        let all = try history.stats()
        self.init(words: all.words, wpm: Int(all.wpm.rounded()),
                  streak: Streak.streak(days: try history.rows().map(\.createdAt), today: today))
    }

    /// The post's text, in our own words. A streak of 0 is left out.
    var text: String {
        let streak = streak > 0 ? ", on a \(streak)-day streak" : ""
        return "I've dictated \(words.formatted()) words with shepetal at \(wpm) words per minute\(streak). "
            + "Voice dictation that never leaves my Mac: \(ShareCard.site)"
    }
}

@MainActor
enum ShareCard {
    nonisolated static let site = "https://shepetal.backant.io"
    /// 600 × 315 pt at 2× is 1200 × 630 px, the size link previews and posts show uncropped.
    static let size = CGSize(width: 600, height: 315)
    static let scale: CGFloat = 2

    static func png(_ stats: ShareStats) -> Data? {
        let r = ImageRenderer(content: ShareCardView(stats: stats))
        r.scale = scale
        guard let image = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// X's prefilled post. Opening it posts nothing: the user sends it there, or not.
    static func postURL(_ stats: ShareStats) -> URL {
        var c = URLComponents(string: "https://x.com/intent/post")!
        c.queryItems = [URLQueryItem(name: "text", value: stats.text)]
        return c.url!
    }
}

/// What the sheet's buttons do. The pasteboard and the browser are passed in, so tests never touch the user's.
@MainActor
struct ShareActions {
    let stats: ShareStats
    let pasteboard: NSPasteboard
    let open: (URL) -> Void

    /// The PNG, plus TIFF for apps that read only that. Returns the note the sheet shows.
    func copy() -> String {
        guard let png = ShareCard.png(stats) else { return "Could not make the image" }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        return "Copied: paste it into a message or a post"
    }

    func save(to url: URL) -> String {
        guard let png = ShareCard.png(stats) else { return "Could not make the image" }
        do { try png.write(to: url); return "Saved \(url.lastPathComponent)" } catch { return "Could not save: \(error.localizedDescription)" }
    }

    func post() { open(ShareCard.postURL(stats)) }
}

/// The card: fixed colors, so it looks the same in Light and Dark appearance.
struct ShareCardView: View {
    let stats: ShareStats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("🤫").font(.system(size: 26))
                Text("shepetal").font(.system(size: 26, weight: .semibold, design: .rounded))
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 44) {
                figure(stats.words.formatted(), "words dictated")
                figure("\(stats.wpm)", "words per minute")
                if stats.streak > 0 { figure("\(stats.streak)", "day streak") }
            }
            Spacer()
            Text("Voice dictation that never leaves your Mac").font(.system(size: 15)).opacity(0.55)
        }
        .padding(40)
        .frame(width: ShareCard.size.width, height: ShareCard.size.height, alignment: .leading)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.11), Color(red: 0.16, green: 0.12, blue: 0.27)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 15, weight: .medium)).opacity(0.6)
        }
    }
}

/// Home's Share stats (F118): one button under Insights that opens the card.
struct ShareStatsSection: View {
    let history: History
    @State private var sharing: ShareStats?
    @State private var problem = ""

    var body: some View {
        Section {
            Button("Share stats…") {
                do { sharing = try ShareStats(history); problem = "" } catch { problem = "Share stats: \(error.localizedDescription)" }
            }
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange) }
        }
        .sheet(item: $sharing) { stats in
            ShareStatsSheet(actions: ShareActions(stats: stats, pasteboard: .general, open: { NSWorkspace.shared.open($0) })) {
                sharing = nil
            }
        }
    }
}

struct ShareStatsSheet: View {
    let actions: ShareActions
    let close: () -> Void
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShareCardView(stats: actions.stats).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Copy") { note = actions.copy() }
                Button("Save…", action: save)
                Button("Post…", action: actions.post)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            Text(note.isEmpty ? "Nothing is uploaded. Post opens a prefilled post in your browser." : note)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .onExitCommand(perform: close)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "shepetal-stats.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        note = actions.save(to: url)
    }
}
