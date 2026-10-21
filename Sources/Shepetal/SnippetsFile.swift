import AppKit
import ShepetalCore

/// Settings' Snippets… button (F40).
@MainActor
enum SnippetsFile {
    /// snippets.toml, created with its header first, in the app that opens .toml files, else in the plain-text
    /// editor: a Mac without developer tools has no app for .toml. A failure shows as an alert.
    static func open(_ url: URL) {
        do { try Snippets.create(url) } catch {
            NSAlert(error: error).runModal()
            return
        }
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(toOpen: url) ?? ws.urlForApplication(toOpen: .plainText) else {
            let alert = NSAlert()
            alert.messageText = "No app on this Mac opens text files. The snippets file is \(url.path)."
            alert.runModal()
            return
        }
        ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
        }
    }
}
