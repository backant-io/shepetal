import AppKit
import ShepetalCore

/// What a 🤫 menu item does. The app delegate performs it.
enum MenuAction: Equatable {
    case permissions, download, downloadCleanup, downloadDictionarySupport, signIn, cancelSignIn, buy
    case meeting, showMeeting(String), openMeetings
    case openApp, notes, checkForUpdates
    case pasteLast, copy(String)
    /// Filled in by the app, which owns these choices (`MenuModel.build`'s `provide`).
    case microphone, languages
    case shortcuts, helpCenter, feedback, quit
}

/// One menu item: an action or a submenu. Never a grey line (Pavel, 21.10.26): what cannot be clicked is not in
/// the menu, and its status is on Home.
struct MenuEntry: Equatable {
    var title: String
    var action: MenuAction?
    var submenu: [MenuEntry]?
    var key = ""
    var modifiers: NSEvent.ModifierFlags = []
    /// The alert mark: something has to be done before dictation works.
    var attention = false
}

/// What the menu shows, read by the app each time the menu opens.
struct MenuState {
    var permissionsMissing = false
    var canDownloadEngine = false
    /// The local cleanup model's size while this Mac can run it and has not downloaded it. Optional: the rules
    /// clean up without it, so the offer has no yellow mark.
    var cleanupDownloadMB: Int?
    var downloadingCleanup = false
    /// F39: the keyword model's download (`SpeechMenu.dictionarySupport`), nil when there is nothing to offer.
    var dictionarySupport: DictionarySupport?
    var access: Access = .lifetime
    var signingIn = false
    var recordingMeeting = false
    /// Newest first, as the store lists them.
    var meetings: [Meeting] = []
    /// Newest first.
    var recent: [HistoryEntry] = []
    var pasteLast: Set<Int> = Shortcuts.defaults[.pasteLast] ?? []
    var canCheckForUpdates = false
    var checkForUpdatesTitle = "Check for Updates…"
}

/// The 🤫 menu, short and grouped by intent: what needs doing (only when it does), meetings, the window, updates
/// (only with an updater), the last text, input, help, quit. Everything else is in the shepetal window (Home and
/// Settings).
enum MenuModel {
    static let helpCenter = Site.base.appendingPathComponent("help")
    /// The contact address on the site's terms page; the site has no feedback page.
    static let feedback = URL(string: "mailto:founder@backant.io?subject=shepetal%20feedback")!
    static let pastMeetingsShown = 8
    /// Buy shows from this many trial days left, and after the trial.
    static let buyFromDaysLeft = 7

    /// Top to bottom; the menu has a separator between each two groups.
    static func groups(_ s: MenuState) -> [[MenuEntry]] {
        [contextual(s),
         meetings(s),
         [MenuEntry(title: "Open shepetal", action: .openApp), MenuEntry(title: "Notes…", action: .notes)],
         s.canCheckForUpdates ? [MenuEntry(title: s.checkForUpdatesTitle, action: .checkForUpdates)] : [],
         [paste(s.pasteLast)] + (recent(s.recent).isEmpty ? [] : [MenuEntry(title: "Recent", submenu: recent(s.recent))]),
         [MenuEntry(title: "Shortcuts…", action: .shortcuts), MenuEntry(title: "Microphone", action: .microphone),
          MenuEntry(title: "Languages", action: .languages)],
         [MenuEntry(title: "Help center", action: .helpCenter), MenuEntry(title: "Send feedback…", action: .feedback)],
         [MenuEntry(title: "Quit shepetal", action: .quit, key: "q", modifiers: .command)]]
            .filter { !$0.isEmpty }
    }

    /// Empty most of the time.
    static func contextual(_ s: MenuState) -> [MenuEntry] {
        var e: [MenuEntry] = []
        if s.permissionsMissing { e.append(MenuEntry(title: "Permissions needed…", action: .permissions, attention: true)) }
        if s.canDownloadEngine {
            e.append(MenuEntry(title: "Download on-device speech recognition (about 470 MB)", action: .download, attention: true))
        }
        // A download's item is hidden while it runs, so a second click cannot start a second download.
        if let mb = s.cleanupDownloadMB, !s.downloadingCleanup {
            e.append(MenuEntry(title: "Download cleanup model (about \(String(format: "%.1f", Double(mb) / 1000)) GB)", action: .downloadCleanup))
        }
        if s.dictionarySupport == .offered {
            e.append(MenuEntry(title: "Download dictionary support (about 100 MB)", action: .downloadDictionarySupport))
        }
        return e + account(s.access, signingIn: s.signingIn)
    }

    /// Sign in while signed out; Buy (the plan choice on the site) near the end of the trial and after a trial or
    /// a subscription ends. A failed payment is fixed on Home, under Manage subscription. The rest is on Home.
    static func account(_ access: Access, signingIn: Bool) -> [MenuEntry] {
        let buy = [MenuEntry(title: AccountText.buyMenu, action: .buy)]
        switch access {
        case .signedOut where signingIn: return [MenuEntry(title: "Cancel sign-in", action: .cancelSignIn)]
        case .signedOut: return [MenuEntry(title: "Sign in to start your free trial…", action: .signIn)]
        case let .trial(days): return days <= buyFromDaysLeft ? buy : []
        case .expired, .subscriptionEnded: return buy
        case .lifetime, .subscription, .paymentFailed, .unchecked: return []
        }
    }

    static func meetings(_ s: MenuState) -> [MenuEntry] {
        let record = MenuEntry(title: s.recordingMeeting ? "Stop meeting recording" : "Record meeting", action: .meeting)
        let past = s.meetings.filter { $0.endedAt != nil }.prefix(pastMeetingsShown)
        guard !past.isEmpty else { return [record, MenuEntry(title: "Open Meetings", action: .openMeetings)] }
        return [record, MenuEntry(title: "Past meetings",
                                  submenu: past.map { MenuEntry(title: MeetingFormat.headline($0), action: .showMeeting($0.id)) })]
    }

    /// The chord shown right-aligned like any macOS shortcut, or in the title when a menu cannot show it.
    static func paste(_ chord: Set<Int>) -> MenuEntry {
        guard let (key, modifiers) = keyEquivalent(chord) else {
            return MenuEntry(title: "Paste last transcript (\(Key.label(chord)))", action: .pasteLast)
        }
        return MenuEntry(title: "Paste last transcript", action: .pasteLast, key: key, modifiers: modifiers)
    }

    /// ⌃⌘V as a menu key equivalent: one key that types a character plus ⌃ ⌥ ⇧ ⌘. nil with fn, a mouse button,
    /// or a key like Space or F5.
    static func keyEquivalent(_ chord: Set<Int>) -> (String, NSEvent.ModifierFlags)? {
        let flags: [Int: NSEvent.ModifierFlags] = [Key.ctrl: .control, Key.opt: .option, Key.shift: .shift, Key.cmd: .command]
        let keys = Set(chord.map(Key.normal))
        let others = keys.filter { flags[$0] == nil }
        guard others.count == 1, let k = others.first, Key.label([k]).count == 1 else { return nil }
        return (Key.label([k]).lowercased(), NSEvent.ModifierFlags(keys.compactMap { flags[$0] }))
    }

    /// Each click copies; a dictation without text has nothing to copy and is left out.
    static func recent(_ rows: [HistoryEntry]) -> [MenuEntry] {
        rows.filter { !$0.shownText.isEmpty }.map { MenuEntry(title: String($0.shownText.prefix(60)), action: .copy($0.shownText)) }  // Show raw (F48)
    }

    /// Fills `menu` with `groups`. Every item calls `action` on `target` with its MenuAction as representedObject;
    /// `provide` returns the items the app builds itself (Microphone, Languages). `head`, when given, is the state in
    /// words at the top (design/ui/components/Menu), e.g. the indicator's `stateName`.
    static func build(_ groups: [[MenuEntry]], into menu: NSMenu, target: AnyObject, action: Selector, head: String? = nil,
                      provide: (MenuAction) -> NSMenuItem? = { _ in nil }) {
        menu.removeAllItems()
        menu.autoenablesItems = false  // every item is enabled; AppKit does not get to grey one out
        menu.font = SH.appBody.nsFont  // Archivo, as everything you operate
        if let head { menu.addItem(Self.head(head)) }
        for (n, group) in groups.enumerated() {
            if n > 0 { menu.addItem(.separator()) }
            for e in group { menu.addItem(item(e, target: target, action: action, provide: provide)) }
        }
    }

    /// The state in words: a section header in the mono label, sh-text-muted. It names, it does nothing.
    static func head(_ state: String) -> NSMenuItem {
        let i = NSMenuItem.sectionHeader(title: state)
        i.attributedTitle = NSAttributedString(string: state, attributes: [.font: SH.label.nsFont, .foregroundColor: SH.textMuted.nsColor])
        return i
    }

    /// The menu bar icon: the Noto 🤫 (never a typed emoji) at 16 pt in an 18 pt square, with a 2 pt sh-signal ring
    /// while `live` (a meeting records). Not a template: the artwork keeps its colors on a light and a dark menu bar.
    static func statusIcon(live: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let side: CGFloat = live ? 12 : 16
            SHIndicator.shush.draw(in: NSRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2, width: side, height: side))
            if live, let ring = IndicatorRing.path(.recording, in: rect) {
                SH.signal.nsColor.setStroke()
                ring.stroke()
            }
            return true
        }
        image.accessibilityDescription = live ? "shepetal, recording" : "shepetal"
        return image
    }

    /// Lucide's triangle-alert, 16 pt at 1.5 pt, as a template so it takes the menu's text color.
    static let attentionIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            let s = rect.width / SHIconShape.grid
            let path = NSBezierPath(cgPath: SHIconName.triangleAlert.path.cgPath)
            path.transform(using: AffineTransform(scaleByX: s, byY: s))
            path.lineWidth = SHIconShape.stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Needs attention"
        return image
    }()

    private static func item(_ e: MenuEntry, target: AnyObject, action: Selector, provide: (MenuAction) -> NSMenuItem?) -> NSMenuItem {
        if let a = e.action, let provided = provide(a) { return provided }
        let i = NSMenuItem(title: e.title, action: e.action == nil ? nil : action, keyEquivalent: e.key)
        i.keyEquivalentModifierMask = e.modifiers
        i.target = target
        i.representedObject = e.action
        if let sub = e.submenu {
            i.submenu = NSMenu()
            build([sub], into: i.submenu!, target: target, action: action, provide: provide)
        }
        if e.attention { i.image = attentionIcon }
        return i
    }
}

/// Check for Updates…: `SparkleUpdater` in release builds (Install.swift).
@MainActor
protocol UpdateChecking {
    /// The item shows, enabled, only when this is true: never a grey item (Pavel, 21.10.26).
    var canCheckForUpdates: Bool { get }
    /// "Update to 0.2.1…" once a scheduled check found one that waits for the user.
    var menuTitle: String { get }
    func checkForUpdates()
}

/// Builds without a feed (from source, test builds): the item is hidden.
struct NoUpdateChecker: UpdateChecking {
    var canCheckForUpdates: Bool { false }
    var menuTitle: String { "Check for Updates…" }
    func checkForUpdates() {}
}
