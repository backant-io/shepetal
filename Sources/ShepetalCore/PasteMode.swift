import Foundation

/// F22: how the text goes into one app. Local Mac terminals need no mode of their own: they take plain ⌘V, and
/// shepetal sends no key markers (docs/re/insertion-context.md M8). Rule 8 gates every mode the same way.
public enum PasteMode: String, CaseIterable, Sendable {
    /// The clipboard and ⌘V; a read after the chord is the paste.
    case local
    /// A remote desktop or VM viewer: the clipboard, a delay so the viewer can sync it, then ⌘V. A read before
    /// or after the chord is the paste, and the old clipboard comes back only after a grace period.
    case remote
    /// As `remote`, with Shift+Insert as the chord: Linux terminals inside a remote session.
    case shiftInsert = "shift-insert"
    /// Key presses from the current keyboard layout; the clipboard is not touched.
    case typed

    /// The user's per-app choice: `defaults write io.backant.shepetal pasteModes -dict-add <bundle id> typed`.
    public static let overridesKey = "pasteModes"
    /// Milliseconds between the clipboard write and the chord in the remote modes.
    public static let delayKey = "pasteDelayMs"
    public static let defaultDelay: TimeInterval = 0.3
    /// Remote modes: the old clipboard comes back this long after the chord or the read, whichever is later, so a
    /// viewer that fetches late cannot paste it.
    public static let remoteGrace: TimeInterval = 1.0

    /// Viewers whose clipboard syncs to another machine. Checked on this Mac's apps: Windows App (it kept
    /// Microsoft Remote Desktop's id) and Screen Sharing. RealVNC and TigerVNC are Wispr's own list
    /// (docs/re/insertion-context.md). The rest are the vendors' ids, unchecked until hand step M-INS-9; a wrong
    /// one never matches, and `pasteModes` fixes it per app.
    public static let remoteViewers: Set<String> = [
        "com.microsoft.rdc.macos",            // Windows App, Microsoft Remote Desktop
        "com.apple.ScreenSharing",
        "com.realvnc.vncviewer", "com.realvnc.rvncconnect", "com.tigervnc.tigervnc",
        "com.p5sys.jump.mac.viewer",          // Jump Desktop
        "com.edovia.screens4.mac", "com.edovia.screens5.mac",
        "tv.parsec.www",
        "com.teamviewer.TeamViewer",
        "com.philandro.anydesk",
        "com.citrix.receiver.icaviewer.mac",  // Citrix Viewer, the Workspace session window
        "com.parallels.desktop.console",
        "com.vmware.fusion",
        "com.utmapp.UTM",
    ]

    public var syncsClipboard: Bool { self == .remote || self == .shiftInsert }

    /// The user's override for the app, else the built-in table. An unknown override value is ignored.
    public static func mode(for bundleId: String, overrides: [String: Any]?) -> PasteMode {
        if let raw = overrides?[bundleId] as? String, let mode = PasteMode(rawValue: raw) { return mode }
        return remoteViewers.contains(bundleId) ? .remote : .local
    }

    public static func current(for bundleId: String, defaults: UserDefaults = .standard) -> PasteMode {
        mode(for: bundleId, overrides: defaults.dictionary(forKey: overridesKey))
    }

    public static func delay(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let ms = defaults.integer(forKey: delayKey)
        return ms > 0 ? TimeInterval(ms) / 1000 : defaultDelay
    }

    /// `requestedAt` is the first read since the clipboard write. Local: only a read after the chord counts.
    /// Remote: any read counts, since an eager viewer syncs during the delay and the far side pastes its copy.
    /// ponytail: a clipboard manager that ignores the Concealed marker and reads during the delay also counts.
    public static func verdict(_ mode: PasteMode, postedAt: TimeInterval, requestedAt: TimeInterval?,
                               now: TimeInterval) -> PasteCheck.Verdict {
        if mode.syncsClipboard, requestedAt != nil { return .landed }
        return PasteCheck.verdict(postedAt: postedAt, requestedAt: requestedAt, now: now)
    }

    /// When to put the user's clipboard back.
    public static func restoreAt(_ mode: PasteMode, postedAt: TimeInterval, requestedAt: TimeInterval?) -> TimeInterval {
        guard mode.syncsClipboard else { return PasteCheck.restoreAt(postedAt: postedAt, requestedAt: requestedAt) }
        return max(postedAt, requestedAt ?? postedAt) + remoteGrace
    }

    /// One key press of the typed mode: a virtual key code and the modifiers it needs.
    public struct Keystroke: Equatable, Sendable {
        public var code: UInt16
        public var shift = false
        public var option = false
        public init(code: UInt16, shift: Bool = false, option: Bool = false) {
            self.code = code; self.shift = shift; self.option = option
        }
    }

    /// The key presses that type `text` on `layout` (character to key), or nil when one character has no key:
    /// the text then goes to the clipboard with the ⌘V hint. A line break has none on purpose, since Return
    /// would send a chat message or run a terminal line.
    public static func keystrokes(_ text: String, layout: [Character: Keystroke]) -> [Keystroke]? {
        let keys = text.compactMap { layout[$0] }
        return keys.count == text.count ? keys : nil
    }
}
