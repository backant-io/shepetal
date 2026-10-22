import AppKit
import ShepetalCore
import XCTest
@testable import Shepetal

/// The 🤫 menu after Pavel compared it with Wispr Flow's (2026-10-21): ours had 22 items with grey status lines,
/// account and setup items mixed in. It is now short and grouped by intent, shows what needs doing only when it
/// does, has no grey item anywhere (Pavel, 21.10.26: every item is actionable or hidden), and everything it lost
/// lives in the shepetal window. Built from MenuState alone: no app, no screen, and never the user's clipboard
/// (the copy test uses a private pasteboard).
@MainActor
final class MenuModelTests: XCTestCase {
    private let day: TimeInterval = 86400

    private func titles(_ groups: [[MenuEntry]]) -> [[String]] { groups.map { $0.map(\.title) } }

    /// Every title in the menu, submenus included.
    private func allTitles(_ entries: [MenuEntry]) -> [String] {
        entries.flatMap { [$0.title] + allTitles($0.submenu ?? []) }
    }

    private func meeting(_ n: Int, ended: Bool = true) -> Meeting {
        let start = Date(timeIntervalSince1970: 1_800_000_000 - Double(n) * day)
        return Meeting(id: "m\(n)", app: "zoom.us", startedAt: start, endedAt: ended ? start + 1800 : nil,
                       meAudioPath: "", othersAudioPath: "")
    }

    private func entry(_ text: String, _ outcome: Outcome = .inserted, at date: Date = Date()) -> HistoryEntry {
        HistoryEntry(id: UUID().uuidString, createdAt: date, outcome: outcome, audioPath: "", durationMs: 1000, text: text)
    }

    /// Everything that can show at once: what Pavel sees on a bad day.
    private var busy: MenuState {
        MenuState(permissionsMissing: true, canDownloadEngine: true, cleanupDownloadMB: 1281, access: .trial(daysLeft: 3),
                  recordingMeeting: true, meetings: (0..<12).map { meeting($0) },
                  recent: [entry("Send the report today."), entry("", .tooShort)], canCheckForUpdates: true)
    }

    /// A normal day once the updater ships: something dictated, nothing to do.
    private var normalDay: MenuState { MenuState(recent: [entry("Send the report today.")], canCheckForUpdates: true) }

    func testTheMenuIsShortAndGroupedByIntent() {
        XCTAssertEqual(titles(MenuModel.groups(normalDay)), [
            ["Record meeting", "Open Meetings"],
            ["Open shepetal", "Notes…"],
            ["Check for Updates…"],
            ["Paste last transcript", "Recent"],
            ["Shortcuts…", "Microphone", "Languages"],
            ["Help center", "Send feedback…"],
            ["Quit shepetal"],
        ], "on a normal day nothing comes before the meetings, and there are no grey status lines")
        XCTAssertEqual(MenuModel.groups(normalDay).joined().count, 13, "it had 22 items")
        XCTAssertEqual(titles(MenuModel.groups(MenuState())), [
            ["Record meeting", "Open Meetings"],
            ["Open shepetal", "Notes…"],
            ["Paste last transcript"],
            ["Shortcuts…", "Microphone", "Languages"],
            ["Help center", "Send feedback…"],
            ["Quit shepetal"],
        ], "no updater yet and nothing dictated: Check for Updates… and Recent are hidden, not greyed out")
    }

    func testWhatNeedsDoingShowsOnlyThenAndAtTheTop() throws {
        func top(_ s: MenuState) -> [MenuEntry] { MenuModel.contextual(s) }
        XCTAssertEqual(top(MenuState()), [], "all granted, engine ready, yours forever: nothing extra")

        let permissions = try XCTUnwrap(top(MenuState(permissionsMissing: true)).first)
        XCTAssertEqual(permissions.title, "Permissions needed…")
        XCTAssertEqual(permissions.action, .permissions)
        XCTAssertTrue(permissions.attention, "the yellow line")

        XCTAssertEqual(top(MenuState(access: .signedOut)).map(\.title), ["Sign in to start your free trial…"])
        XCTAssertEqual(top(MenuState(access: .signedOut)).first?.action, .signIn)
        XCTAssertEqual(top(MenuState(access: .signedOut, signingIn: true)).map(\.title), ["Cancel sign-in"],
                       "a sheet stuck in a browser can be closed from the menu")

        let buy = ["Get shepetal: $23.99 once or $0.99 a month…"]
        XCTAssertEqual(top(MenuState(access: .trial(daysLeft: 30))).map(\.title), [], "no nagging early in the trial")
        XCTAssertEqual(top(MenuState(access: .trial(daysLeft: 8))).map(\.title), [])
        XCTAssertEqual(top(MenuState(access: .trial(daysLeft: 7))).map(\.title), buy, "from 7 days left")
        XCTAssertEqual(top(MenuState(access: .trial(daysLeft: 0))).map(\.title), buy)
        XCTAssertEqual(top(MenuState(access: .expired)).map(\.title), buy, "and after the trial")
        XCTAssertEqual(top(MenuState(access: .expired)).first?.action, .buy)
        XCTAssertEqual(top(MenuState(access: .lifetime)), [])
        XCTAssertEqual(top(MenuState(access: .unchecked)), [], "Check license now is on Home")
        // The plans: a subscriber has nothing to buy; an ended subscription buys again; a failed payment is fixed on Home.
        XCTAssertEqual(top(MenuState(access: .subscription(paidThrough: Date() + 86_400, renews: true))), [])
        XCTAssertEqual(top(MenuState(access: .subscription(paidThrough: Date() + 86_400, renews: false))), [])
        XCTAssertEqual(top(MenuState(access: .subscriptionEnded)).map(\.title), buy)
        XCTAssertEqual(top(MenuState(access: .paymentFailed)), [], "Manage subscription is on Home")

        XCTAssertEqual(top(MenuState(canDownloadEngine: true)).map(\.action), [.download])
        XCTAssertEqual(top(MenuState(canDownloadEngine: false)), [],
                       "loading, downloading or could not start: no grey status line, Home's Speech recognition line says it")

        let groups = MenuModel.groups(busy)
        XCTAssertEqual(groups[0].map(\.title), ["Permissions needed…", "Download on-device speech recognition (about 470 MB)",
                                                 "Download cleanup model (about 1.3 GB)", "Get shepetal: $23.99 once or $0.99 a month…"],
                       "every contextual item is in the first group")
        XCTAssertEqual(groups[1].first?.title, "Stop meeting recording", "then the menu as usual")
    }

    /// The local cleanup model is optional (the rules clean up without it), so the menu offers it without the
    /// yellow mark, and only until it is downloaded. Its status is Home's Cleanup line, not a grey menu line.
    func testTheCleanupModelIsOfferedUntilItIsDownloaded() throws {
        func top(_ s: MenuState) -> [MenuEntry] { MenuModel.contextual(s) }
        XCTAssertEqual(top(MenuState(cleanupDownloadMB: nil)), [], "downloaded, or an Intel Mac: nothing")
        let offer = try XCTUnwrap(top(MenuState(cleanupDownloadMB: 1281)).first)
        XCTAssertEqual(offer.title, "Download cleanup model (about 1.3 GB)")
        XCTAssertEqual(offer.action, .downloadCleanup)
        XCTAssertFalse(offer.attention, "dictation works without it")
        XCTAssertEqual(top(MenuState(cleanupDownloadMB: 533)).map(\.title), ["Download cleanup model (about 0.5 GB)"], "8 GB Macs")

        XCTAssertEqual(top(MenuState(cleanupDownloadMB: 1281, downloadingCleanup: true)), [],
                       "no download item while it runs, so a second click cannot start a second download, and no grey line")
        XCTAssertEqual(top(MenuState(cleanupDownloadMB: 1281)).map(\.action), [.downloadCleanup],
                       "after a failed download the item is back; the failure is on Home's Cleanup line")
        XCTAssertTrue(try AppSource.code("Pipeline.swift").contains(
            "cleanupStatus = \"Rules only (the download failed; try again from the 🤫 menu)\""))
    }

    /// F39 (#30): the keyword model's download is with what needs doing, only while SpeechMenu offers it (speech
    /// recognition there, words in the dictionary, keyword model missing), and hidden while it runs.
    func testDictionarySupportShowsOnlyWhenOfferedAndHidesWhileItDownloads() throws {
        XCTAssertEqual(MenuModel.groups(normalDay).joined().count, 13, "a normal day keeps the 13 items")

        let offered = MenuModel.contextual(MenuState(dictionarySupport: .offered))
        XCTAssertEqual(offered, [MenuEntry(title: "Download dictionary support (about 100 MB)", action: .downloadDictionarySupport)])
        XCTAssertEqual(MenuModel.groups(MenuState(dictionarySupport: .offered))[0], offered, "at the top")
        XCTAssertEqual(MenuModel.contextual(MenuState(dictionarySupport: .downloading)), [],
                       "hidden while it runs: a second click starts nothing, and the notice next to 🤫 says it is downloading")
        XCTAssertTrue(ModelNameTests.offending("\"\(offered[0].title)\"").isEmpty, "model name in \(offered[0].title)")

        let m = NSMenu()
        MenuModel.build(MenuModel.groups(MenuState(dictionarySupport: .offered)), into: m, target: self, action: #selector(noop(_:)))
        XCTAssertEqual(m.items.first?.representedObject as? MenuAction, .downloadDictionarySupport)

        let app = try AppSource.code("App.swift")
        for line in ["dictionarySupport: speech.dictionarySupport(),", "case .downloadDictionarySupport: speech.downloadBoost()",
                     "speech.notice = { [weak self] in self?.indicator.show($0, seconds: 4) }"] {
            XCTAssertTrue(app.contains(line), "App.swift: \(line)")
        }
    }

    func testMeetingsRecordAndListThePastOnesNewestFirst() throws {
        XCTAssertEqual(MenuModel.meetings(MenuState(recordingMeeting: false)).first, MenuEntry(title: "Record meeting", action: .meeting))
        XCTAssertEqual(MenuModel.meetings(MenuState(recordingMeeting: true)).first?.title, "Stop meeting recording")
        XCTAssertEqual(MenuModel.meetings(MenuState(recordingMeeting: true)).first?.action, .meeting)

        let running = meeting(-1, ended: false)
        let past = (0..<12).map { meeting($0) }
        let group = MenuModel.meetings(MenuState(recordingMeeting: true, meetings: [running] + past))
        XCTAssertEqual(group.map(\.title), ["Stop meeting recording", "Past meetings"])
        let list = try XCTUnwrap(group[1].submenu)
        XCTAssertEqual(list.map(\.action), past.prefix(8).map { .showMeeting($0.id) },
                       "the 8 newest ended meetings, each opening its transcript; not the one still recording")
        XCTAssertEqual(list.map(\.title), past.prefix(8).map { MeetingFormat.headline($0) })

        XCTAssertEqual(MenuModel.meetings(MenuState(meetings: [running])).map(\.title), ["Record meeting", "Open Meetings"],
                       "no past meeting yet: open the Meetings tab instead of an empty list")
        XCTAssertEqual(MenuModel.meetings(MenuState()).last?.action, .openMeetings)
    }

    func testRecentCopiesAndCopyLastLeftTheMenu() throws {
        let recent = try XCTUnwrap(MenuModel.groups(busy).joined().first { $0.title == "Recent" }?.submenu)
        XCTAssertEqual(recent, [MenuEntry(title: "Send the report today.", action: .copy("Send the report today."))],
                       "no grey heading, and the too-short dictation has nothing to copy, so it is left out")
        for rows in [[], [entry("", .tooShort), entry("", .noSpeech)]] {
            XCTAssertFalse(allTitles(Array(MenuModel.groups(MenuState(recent: rows)).joined())).contains("Recent"),
                           "nothing to copy: no Recent submenu instead of a grey \"Nothing yet\"")
        }

        let everything = allTitles(Array(MenuModel.groups(busy).joined()))
        XCTAssertFalse(everything.contains { $0.contains("Copy last") }, "Copy last text left the menu")
        XCTAssertEqual(Shortcuts().chord(.copyLast), Shortcuts.defaults[.copyLast], "its shortcut, ⌃⌘C, stays")
        let app = try AppSource.code("App.swift")
        XCTAssertTrue(app.contains("case .copyLast: copyLast()"), "⌃⌘C still reaches copy last")
        XCTAssertTrue(app.contains("guard pipeline?.copyLast() != nil else"), "which copies through the pipeline (below)")
        XCTAssertEqual(ShortcutAction.pasteLast.title, MenuModel.paste(MenuState().pasteLast).title,
                       "the Shortcuts window and the menu name it the same")
    }

    /// What ⌃⌘C and a Recent entry put on the clipboard, on a private pasteboard: never the user's.
    func testCopyLastAndRecentPutTheTextOnTheClipboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-test-\(UUID().uuidString)")
        let board = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        board.clearContents()
        board.setString("earlier", forType: .string)
        let pipeline = try Pipeline(root: root, pasteboard: board)

        XCTAssertNil(pipeline.copyLast(), "nothing dictated yet")
        XCTAssertEqual(board.string(forType: .string), "earlier", "and the clipboard is left alone")

        let now = Date()
        try pipeline.history.add(entry("Send the report today.", .pasteFailed, at: now - 60))
        try pipeline.history.add(entry("", .tooShort, at: now))
        XCTAssertEqual(pipeline.copyLast(), "Send the report today.")
        XCTAssertEqual(board.string(forType: .string), "Send the report today.",
                       "⌃⌘C copies the paste that did not land, past a newer entry without text")

        pipeline.copy("Call the dentist.")
        XCTAssertEqual(board.string(forType: .string), "Call the dentist.", "a Recent entry's own text")
    }

    func testPasteLastShowsItsShortcutRightAlignedAndQuitHasCommandQ() throws {
        let menu = NSMenu()
        MenuModel.build(MenuModel.groups(busy), into: menu, target: self, action: #selector(noop(_:)))
        let paste = try XCTUnwrap(menu.items.first { $0.title == "Paste last transcript" }, "no shortcut in the title")
        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertEqual(paste.keyEquivalentModifierMask, [.control, .command], "⌃⌘V, drawn by AppKit")
        let quit = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(quit.title, "Quit shepetal")
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        for i in menu.items where i !== paste && i !== quit {
            XCTAssertEqual(i.keyEquivalent, "", "\(i.title) has no key equivalent")
        }

        // Shortcuts… can rebind it: the menu follows.
        let (ctrl, opt, shift, p) = (Key.ctrl, Key.opt, Key.shift, 35)
        XCTAssertEqual(MenuModel.paste([ctrl, opt, p]).key, "p")
        XCTAssertEqual(MenuModel.paste([ctrl, opt, p]).modifiers, [.control, .option])
        XCTAssertEqual(MenuModel.paste([Key.rightCmd, shift, p]).modifiers, [.command, .shift], "either side of a modifier")
        XCTAssertEqual(MenuModel.paste([Key.mouse(4)]), MenuEntry(title: "Paste last transcript (Mouse 4)", action: .pasteLast),
                       "a menu cannot show a mouse button: the title says it")
        XCTAssertEqual(MenuModel.paste([Key.fn, 9]).title, "Paste last transcript (fn V)")
        XCTAssertEqual(MenuModel.paste([ctrl, Key.space]).key, "", "nor Space")
    }

    func testTheBuiltMenuHasSeparatorsBetweenGroupsAndRoutesEveryItem() throws {
        let groups = MenuModel.groups(busy)
        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let languages = NSMenuItem(title: "Languages", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(withTitle: "stale", action: nil, keyEquivalent: "")
        MenuModel.build(groups, into: menu, target: self, action: #selector(noop(_:))) {
            switch $0 {
            case .microphone: mic
            case .languages: languages
            default: nil
            }
        }
        XCTAssertFalse(menu.items.contains { $0.title == "stale" }, "rebuilt from scratch each time it opens")
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, groups.count - 1)
        let real = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(real.map(\.title), groups.joined().map(\.title))
        XCTAssertTrue(real.contains { $0 === mic } && real.contains { $0 === languages }, "the app's own submenus")
        XCTAssertFalse(menu.autoenablesItems)
        for (i, e) in zip(real, groups.joined()) where i !== mic && i !== languages {
            XCTAssertEqual(i.representedObject as? MenuAction, e.action, i.title)
            if e.action != nil {
                XCTAssertTrue(i.target === self, i.title)
                XCTAssertEqual(i.action, #selector(noop(_:)), i.title)
            }
        }
        XCTAssertNotNil(real[0].image, "Permissions needed… has the yellow mark")
        XCTAssertNil(real.first { $0.title == "Open shepetal" }?.image)
        let past = try XCTUnwrap(real.first { $0.title == "Past meetings" }?.submenu)
        XCTAssertEqual(past.items.first?.representedObject as? MenuAction, .showMeeting("m0"))
        let recent = try XCTUnwrap(real.first { $0.title == "Recent" }?.submenu)
        XCTAssertEqual(recent.items.map { $0.representedObject as? MenuAction }, [.copy("Send the report today.")])

        let updates = { (can: Bool) -> NSMenuItem? in
            let m = NSMenu()
            MenuModel.build(MenuModel.groups(MenuState(canCheckForUpdates: can)), into: m, target: self, action: #selector(self.noop(_:)))
            return m.items.first { $0.title == "Check for Updates…" }
        }
        XCTAssertEqual(updates(true)?.representedObject as? MenuAction, .checkForUpdates)
        XCTAssertEqual(updates(true)?.isEnabled, true)
        XCTAssertNil(updates(false), "hidden until an updater can check, never greyed out")
        XCTAssertFalse(NoUpdateChecker().canCheckForUpdates)
        // With Sparkle the item is always there and enabled: a click while Sparkle downloads says so instead.
        XCTAssertTrue(try AppSource.code("Install.swift").contains("var canCheckForUpdates: Bool { true }"))

        // A found update that waits for Install Now renames the item instead of opening a window at a random moment;
        // the menu keeps its length.
        let found = MenuModel.groups(MenuState(canCheckForUpdates: true, checkForUpdatesTitle: "Update to 0.2.1…"))
        XCTAssertTrue(found.joined().contains { $0.title == "Update to 0.2.1…" && $0.action == .checkForUpdates })
        XCTAssertEqual(found.joined().count, MenuModel.groups(MenuState(canCheckForUpdates: true)).joined().count)
    }

    /// Pavel, 21.10.26: "Menu bar menu must drop all the grayed-out text fields." The real menu, built the way
    /// menuNeedsUpdate builds it (MenuModel plus the app's Microphone, Languages and dictation-off items), for
    /// every kind of day, walked into each submenu: every item can be clicked and does something. With the app
    /// object there, `update()` validates like the real menu does, so AppKit's autoenable cannot grey one out or
    /// undo it either (#207). Fake mics, a throwaway defaults suite and an injected front app: nothing real is
    /// read or changed.
    func testNoItemAnywhereInTheMenuIsGreyedOut() throws {
        _ = NSApplication.shared
        let suite = "shepetal-menu-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let blocked = AppBlockList(defaults)
        blocked.set("com.example.Notes", name: "Notes", off: true)
        let off = DictationOff(list: blocked) { ("com.apple.TextEdit", "TextEdit") }
        let builtIn = MicDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
        let usb = MicDevice(uid: "usb-1", name: "Yeti", transport: .usb)
        let languages = SpeechMenu()

        let full = (0..<10).map { entry($0.isMultiple(of: 3) ? "" : "Dictation \($0).", $0.isMultiple(of: 3) ? .tooShort : .inserted) }
        let days: [(String, MenuState)] = [
            ("normal day", MenuState()),
            ("signed out", MenuState(access: .signedOut)),
            ("signing in", MenuState(access: .signedOut, signingIn: true)),
            ("trial ending", MenuState(access: .trial(daysLeft: 3))),
            ("trial over", MenuState(access: .expired)),
            ("license unchecked", MenuState(access: .unchecked)),
            ("permissions missing", MenuState(permissionsMissing: true)),
            ("speech not ready", MenuState(canDownloadEngine: false)),
            ("speech not downloaded", MenuState(canDownloadEngine: true)),
            ("cleanup model not downloaded", MenuState(cleanupDownloadMB: 1281)),
            ("cleanup model downloading", MenuState(cleanupDownloadMB: 1281, downloadingCleanup: true)),
            ("dictionary support offered", MenuState(dictionarySupport: .offered)),
            ("dictionary support downloading", MenuState(dictionarySupport: .downloading)),
            ("meeting recording, none ended", MenuState(recordingMeeting: true, meetings: [meeting(-1, ended: false)])),
            ("past meetings", MenuState(meetings: (0..<12).map { meeting($0) })),
            ("only too-short dictations", MenuState(recent: [entry("", .tooShort), entry("", .noSpeech)])),
            ("full recents", MenuState(recent: full)),
            ("bad day", busy),
        ]
        var walked = 0
        for (day, base) in days {
            for updater in [false, true] {
                for lidClosed in [false, true] {
                    var state = base
                    state.canCheckForUpdates = updater
                    let mic = Mic(recorder: Recorder(), inputs: { [builtIn, usb] }, isLidClosed: { lidClosed })
                    let menu = NSMenu()
                    MenuModel.build(MenuModel.groups(state), into: menu, target: self, action: #selector(noop(_:))) {
                        switch $0 {
                        case .microphone: mic.menuItem()
                        case .languages: languages.languagesItem()
                        default: nil
                        }
                    }
                    off.menuItems().forEach(menu.addItem)
                    let name = "\(day), updater \(updater ? "on" : "off"), lid \(lidClosed ? "closed" : "open")"
                    walked += assertEveryItemIsActionable(menu, name)

                    let mics = try XCTUnwrap(menu.items.first { $0.title == "Microphone" }?.submenu).items.map(\.title)
                    XCTAssertEqual(mics.contains { $0.contains(builtIn.name) }, !lidClosed,
                                   "\(name): a closed lid's built-in mic is hidden, not greyed out (#207)")
                    XCTAssertTrue(mics.contains("Yeti") && mics.contains("Prefer Yeti"), name)
                }
            }
        }
        XCTAssertGreaterThan(walked, days.count * 4 * 50, "the walk reached the submenus")
    }

    /// Every item in `menu` and its submenus is enabled and has an action its target performs, or a submenu that
    /// is not empty. Separators are not text and stay. Returns how many items it checked.
    private func assertEveryItemIsActionable(_ menu: NSMenu, _ path: String) -> Int {
        XCTAssertFalse(menu.autoenablesItems, "\(path): with autoenable on, AppKit decides what is greyed out (#207)")
        menu.update()
        var checked = 0
        for item in menu.items where !item.isSeparatorItem {
            let at = "\(path) > \(item.title)"
            checked += 1
            XCTAssertTrue(item.isEnabled, "\(at) is greyed out")
            XCTAssertFalse(item.isSectionHeader, "\(at) is a grey heading")
            if let sub = item.submenu {
                XCTAssertTrue(sub.items.contains { !$0.isSeparatorItem }, "\(at) is an empty submenu")
                checked += assertEveryItemIsActionable(sub, at)
            } else if let action = item.action {
                XCTAssertTrue((item.target as? NSObject)?.responds(to: action) == true, "\(at): nothing performs it")
            } else {
                XCTFail("\(at) has no action and no submenu: a plain status line")
            }
        }
        return checked
    }

    func testLabelsUseTheBrandAndNoEmojiOrModelName() {
        let everything = allTitles(Array(MenuModel.groups(busy).joined()))
            + allTitles(MenuModel.account(.signedOut, signingIn: false)) + allTitles(MenuModel.account(.signedOut, signingIn: true))
        for t in everything {
            XCTAssertFalse(t.contains("Shepetal"), "lowercase shepetal: \(t)")
            XCTAssertFalse(t.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }, "emoji in \(t)")
            XCTAssertTrue(ModelNameTests.offending("\"\(t)\"").isEmpty, "model name in \(t)")
        }
        XCTAssertTrue(everything.contains("Open shepetal") && everything.contains("Quit shepetal"))
        XCTAssertEqual(MenuModel.helpCenter.absoluteString, "https://shepetal.app/help")
        XCTAssertEqual(MenuModel.feedback.scheme, "mailto")
    }

    /// Nothing was lost: each item that left the menu is in the window, and is no longer in the menu.
    func testEverySettingThatLeftTheMenuIsInTheWindow() throws {
        let hub = try AppSource.code("Hub.swift")
        let home = try AppSource.body(of: "private struct HomeTab: View {", in: hub)
        let settings = try AppSource.body(of: "private struct SettingsTab: View {", in: hub)
        let account = try AppSource.code("AccountView.swift")
        let moved: [(menu: String, window: String, place: String)] = [
            ("On-device speech recognition", "LabeledContent(\"Speech recognition\", value: s.model)", home),
            ("Cleanup:", "LabeledContent(\"Cleanup\", value: model.pipeline.cleanupStatus)", home),
            ("Signed in as", "Text(account.summaryLine)", account),
            ("Sign out", "Button(\"Sign out\")", account),
            ("Check license now", "Button(\"Check license now\")", account),
            ("Donate", "Section(\"Donate\") {\n                    ForEach(AppDelegate.donate", home),
            ("Recordings", "Picker(\"Recordings\"", settings),
            ("Open recordings folder", "Button(\"Open recordings folder\")", settings),
            ("Start at login", "Toggle(\"Start at login\", isOn: Binding(get: { model.loginItem.isOn }, set: { _ in model.toggleLogin() }))", settings),
            ("Dictionary…", "Button(\"Dictionary…\", action: model.openDictionary)", settings),
            ("Restore 🌐 key setting", "Button(\"Restore 🌐 key setting", settings),
            ("Permissions…", "Button(\"Permissions…\", action: model.openPermissions)", settings),
        ]
        let menu = allTitles(Array(MenuModel.groups(busy).joined()))
        for m in moved {
            XCTAssertTrue(m.place.contains(m.window), "\(m.menu) is missing from the window")
            XCTAssertFalse(menu.contains { $0.hasPrefix(m.menu) }, "\(m.menu) is still in the menu")
        }
        XCTAssertTrue(home.contains("AccountSection()"), "the account and trial line are on Home")
        let shortcutsHint = try AppSource.code("ShortcutsWindow.swift")
        XCTAssertTrue(shortcutsHint.contains("Shortcuts need Input Monitoring. Open Settings > Permissions… in the shepetal window."),
                      "the Shortcuts window sends people where Permissions… is now, not to the menu")
        let app = try AppSource.code("App.swift")
        XCTAssertTrue(app.contains("loginItem: loginItem, openDictionary: { [speech] in speech.openDictionary() },"))
        XCTAssertTrue(app.contains("restoreFnKey: { [weak self] in self?.restoreFnKey() },"))
    }

    /// The glue between the app and the model: the state it reads and the action each item performs. The actions
    /// call AppKit and the account (sign-in sheet, browser, Quit), which a test cannot run, so the dispatch is
    /// checked line for line: a wrong call, a missing case or a new one without its line here fails.
    /// Copying is run for real above (testCopyLastAndRecentPutTheTextOnTheClipboard).
    func testTheAppFeedsTheMenuAndPerformsItsActions() throws {
        let app = try AppSource.code("App.swift")
        func lines(of method: String) throws -> [String] {
            let body = try XCTUnwrap(app.range(of: method), method)
            let rest = app[body.upperBound...]
            return rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)]
                .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        // The whole body, so a line added straight into the menu here (a greyed status line, say) fails (#239):
        // every item comes from MenuModel, plus the submenus and the F102 off switch.
        XCTAssertEqual(try lines(of: "func menuNeedsUpdate(_ menu: NSMenu) {"), [
            "Account.shared.refresh()",
            "let state = MenuState(permissionsMissing: !Permission.missing.isEmpty,",
            "canDownloadEngine: engine == nil && !downloading && !ParakeetEngine.isInstalled,",
            "cleanupDownloadMB: pipeline?.cleanupToDownload?.megabytes,",
            "downloadingCleanup: pipeline?.downloadingCleanup == true,",
            "dictionarySupport: speech.dictionarySupport(),",
            "access: Account.shared.access, signingIn: Account.shared.signingIn,",
            "recordingMeeting: meetings.current != nil,",
            "meetings: (try? meetingFlow?.store.list(limit: MenuModel.pastMeetingsShown + 1)) ?? [],",
            "recent: (try? pipeline?.history.recent(limit: 10)) ?? [],",
            "pasteLast: tap.router.shortcuts.chord(.pasteLast),",
            "canCheckForUpdates: updater.canCheckForUpdates, checkForUpdatesTitle: updater.menuTitle)",
            "MenuModel.build(MenuModel.groups(state), into: menu, target: self, action: #selector(menuAction(_:))) { [mic, speech] in",
            "switch $0 {",
            "case .microphone: mic.menuItem()",
            "case .languages: speech.languagesItem()",
            "default: nil",
            "}",
            "}",
            "let input = menu.items.firstIndex { $0.representedObject as? MenuAction == .helpCenter }.map { $0 - 1 } ?? menu.numberOfItems",
            "for (n, i) in dictationOff.menuItems().enumerated() { menu.insertItem(i, at: input + n) }",
        ])
        XCTAssertTrue(app.contains("Task { await pipeline?.loadCleanup() }"), "the cleanup model loads at launch")
        XCTAssertEqual(try lines(of: "@objc private func menuAction(_ sender: NSMenuItem) {").filter { $0.hasPrefix("case .") }, [
            "case .permissions: showOnboarding()",
            "case .download: downloadModel()",
            "case .downloadCleanup: Task { if let failed = await pipeline?.downloadCleanup() { fail(failed) } }",
            "case .downloadDictionarySupport: speech.downloadBoost()",
            "case .signIn: Account.shared.signIn()",
            "case .cancelSignIn: Account.shared.cancelSignIn()",
            "case .buy: Account.shared.buy()",
            "case .meeting: meetings.toggle()",
            "case .showMeeting(let id): if let m = try? meetingFlow?.store.get(id)?.meeting { openTranscript(m) }",
            "case .openMeetings: openedHub()?.showMeetings()",
            "case .openApp: openHub()",
            "case .notes: openNotes()",
            "case .checkForUpdates: updater.checkForUpdates()",
            "case .pasteLast: pasteLast()",
            "case .copy(let text): pipeline?.copy(text)",
            "case .shortcuts: openShortcuts()",
            "case .helpCenter: NSWorkspace.shared.open(MenuModel.helpCenter)",
            "case .feedback: NSWorkspace.shared.open(MenuModel.feedback)",
            "case .quit: NSApp.terminate(nil)",
            "case .microphone, .languages: break  // their own submenus",
        ])
        XCTAssertTrue(app.contains("openTranscript = MeetingTranscriptWindow.follow(meetingFlow)"))
        XCTAssertTrue(app.contains("private func openHub() { openedHub()?.show() }"), "Open shepetal shows the window")
        // F55: Notes… and the open-notes shortcut open the same notes window, kept in the owner-only data dir.
        XCTAssertTrue(app.contains("case .openNotes: openNotes()"), "the open-notes shortcut reaches the notes window")
        XCTAssertEqual(try lines(of: "private func openNotes() {"), [
            "do { notes = try notes ?? NotesWindow.onDisk() } catch { return fail(\"Notes could not open: \\(error.localizedDescription)\") }",
            "notes?.show()",
        ], "one notes window for the app's life, shown in front; a file it cannot open says so next to 🤫")
        let download = try lines(of: "private func downloadModel() {")
        XCTAssertEqual(Array(download.prefix(2)), ["guard !downloading else { return }", "downloading = true"],
                       "a second click while it downloads starts nothing")
        XCTAssertTrue(download.contains("defer { downloading = false }"), "and after a failed download the item is back")
        XCTAssertTrue(download.contains(#"fail("Speech recognition download failed: " + reason)  // the menu's Download item is back, so say why (#239)"#),
                      "a failed download says so next to 🤫, not only on Home (#239)")
        XCTAssertTrue(try lines(of: "private func loadEngine() async {")
            .contains(#"fail(couldNotStart ? "No speech recognition. See Home in the shepetal window." : "No speech recognition. Open the 🤫 menu.")"#),
                      "a model that is installed but cannot start points at Home: the menu has nothing for it (#239)")
    }

    @objc private func noop(_ sender: NSMenuItem) {}
}

/// Sources/Shepetal read as text, comment lines dropped: the SwiftUI window and the app delegate cannot run here.
enum AppSource {
    static func code(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Shepetal/\(file)").standardizedFileURL
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    /// From `start` to the next top-level declaration.
    static func body(of start: String, in source: String) throws -> String {
        let from = try XCTUnwrap(source.range(of: start), start)
        let rest = source[from.upperBound...]
        return String(rest[..<(rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex)])
    }
}
