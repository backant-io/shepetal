import AppKit
import SwiftUI

/// The chrome of shepetal's small windows (onboarding, Shortcuts, What's new, the notes): the Mac title bar of
/// design/ui/components/TitleBar, 40 pt and unified, the content drawn under it on sh-bg with the native traffic
/// lights, and the title centered in app-strong 13 pt by `SmallWindowTitle`. The window follows the OS appearance:
/// sh-bg is a dynamic color, never a pinned appearance.
@MainActor
enum SmallWindow {
    static let titleBar: CGFloat = 40

    /// `drawsTitle`: false keeps the system's title (the notes window, whose tabs show each note's title).
    static func style(_ window: NSWindow, drawsTitle: Bool = true) {
        window.backgroundColor = SH.bg.nsColor
        window.titlebarAppearsTransparent = true
        if drawsTitle {
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
    }
}

/// The title, centered in the 40 pt bar the content is drawn under. The bar is the window's drag region.
struct SmallWindowTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .shText(SH.appStrong.with(size: 13))
            .foregroundStyle(SH.text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: SmallWindow.titleBar, maxHeight: SmallWindow.titleBar)
            .accessibilityAddTraits(.isHeader)
    }
}
