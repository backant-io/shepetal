import AppKit
import ShepetalCore

/// What a 🤫 menu item does. The app delegate performs it.
enum MenuAction: Equatable {
    case permissions, download, downloadCleanup, downloadDictionarySupport, signIn, cancelSignIn, buy
    case meeting, showMeeting(String), openMeetings
    case openApp, checkForUpdates
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
    /// The yellow mark: something has to be done before dictation works.
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
    static let helpCenter = URL(string: "https://shepetal.backant.io/help")!
    /// The contact address on shepetal.backant.io (web/ terms page); the site has no feedback page.
    static let feedback = URL(string: "mailto:founder@backant.io?subject=shepetal%20feedback")!
    static let pastMeetingsShown = 8
    /// Buy shows from this many trial days left, and after the trial.
    static let buyFromDaysLeft = 7

    /// Top to bottom; the menu has a separator between each two groups.
    static func groups(_ s: MenuState) -> [[MenuEntry]] {
        [contextual(s),
         meetings(s),
         [MenuEntry(title: "Open shepetal", action: .openApp)],
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

    /// Sign in while signed out; Buy near the end of the trial and after it. The rest is on Home.
    static func account(_ access: Access, signingIn: Bool) -> [MenuEntry] {
        let buy = [MenuEntry(title: "Get shepetal for $4.99…", action: .buy)]
        switch access {
        case .signedOut where signingIn: return [MenuEntry(title: "Cancel sign-in", action: .cancelSignIn)]
        case .signedOut: return [MenuEntry(title: "Sign in to start your free trial…", action: .signIn)]
        case let .trial(days): return days <= buyFromDaysLeft ? buy : []
        case .expired: return buy
        case .lifetime, .unchecked: return []
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
        rows.filter { !$0.text.isEmpty }.map { MenuEntry(title: String($0.text.prefix(60)), action: .copy($0.text)) }
    }

    /// Fills `menu` with `groups`. Every item calls `action` on `target` with its MenuAction as representedObject;
    /// `provide` returns the items the app builds itself (Microphone, Languages).
    static func build(_ groups: [[MenuEntry]], into menu: NSMenu, target: AnyObject, action: Selector,
                      provide: (MenuAction) -> NSMenuItem? = { _ in nil }) {
        menu.removeAllItems()
        menu.autoenablesItems = false  // every item is enabled; AppKit does not get to grey one out
        for (n, group) in groups.enumerated() {
            if n > 0 { menu.addItem(.separator()) }
            for e in group { menu.addItem(item(e, target: target, action: action, provide: provide)) }
        }
    }

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
        if e.attention {
            i.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemYellow]))
        }
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
