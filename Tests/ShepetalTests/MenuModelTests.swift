import AppKit
import ShepetalCore
import XCTest
@testable import Shepetal

/// The 🤫 menu after Pavel compared it with Wispr Flow's (2026-10-21): ours had 22 items with grey status lines,
/// account and setup items mixed in. It is now short and grouped by intent, shows what needs doing only when it
/// does, and everything it lost lives in the shepetal window. Built from MenuState alone: no app, no screen,
/// no clipboard (nothing here performs an item's action).
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

    private func entry(_ text: String, _ outcome: Outcome = .inserted) -> HistoryEntry {
        HistoryEntry(id: UUID().uuidString, createdAt: Date(), outcome: outcome, audioPath: "", durationMs: 1000, text: text)
    }

    /// Everything that can show at once: what Pavel sees on a bad day.
    private var busy: MenuState {
        MenuState(permissionsMissing: true, engineProblem: "Loading on-device speech recognition…", canDownloadEngine: true,
                  cleanupDownloadMB: 1281, cleanupDownloadFailed: true, access: .trial(daysLeft: 3), recordingMeeting: true, meetings: (0..<12).map { meeting($0) },
                  recent: [entry("Send the report today."), entry("", .tooShort)], canCheckForUpdates: true)
    }

    func testTheMenuIsShortAndGroupedByIntent() {
        XCTAssertEqual(titles(MenuModel.groups(MenuState())), [
            ["Record meeting", "Open Meetings"],
            ["Open shepetal"],
            ["Check for Updates…"],
            ["Paste last transcript", "Recent"],
            ["Shortcuts…", "Microphone", "Languages"],
            ["Help center", "Send feedback…"],
            ["Quit shepetal"],
        ], "on a normal day nothing comes before the meetings, and there are no grey status lines")
        XCTAssertEqual(MenuModel.groups(MenuState()).joined().count, 12, "it had 22 items")
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

        let buy = ["Get shepetal for $4.99…"]
        XCTAssertEqual(top(MenuState(access: .trial(daysLeft: 30))).map(\.title), [], "no nagging early in the trial")
        XCTAssertEqual(top(MenuState(access: .trial(daysLeft: 8))).map(\.title), [])
        XCTAssertEqual(top(MenuState(access: .trial(daysLeft: 7))).map(\.title), buy, "from 7 days left")
        XCTAssertEqual(top(MenuState(access: .trial(daysLeft: 0))).map(\.title), buy)
        XCTAssertEqual(top(MenuState(access: .expired)).map(\.title), buy, "and after the trial")
        XCTAssertEqual(top(MenuState(access: .expired)).first?.action, .buy)
        XCTAssertEqual(top(MenuState(access: .lifetime)), [])
        XCTAssertEqual(top(MenuState(access: .unchecked)), [], "Check license now is on Home")

        let engine = top(MenuState(engineProblem: "Download failed: check the internet connection and try again"))
        XCTAssertEqual(engine.map(\.title), ["Download failed: check the internet connection and try again"])
        XCTAssertFalse(engine[0].enabled, "a grey line, only while speech recognition is not ready")
        XCTAssertEqual(top(MenuState(canDownloadEngine: true)).map(\.action), [.download])

        let groups = MenuModel.groups(busy)
        XCTAssertEqual(groups[0].map(\.title), ["Permissions needed…", "Loading on-device speech recognition…",
                                                 "Download on-device speech recognition (about 470 MB)",
                                                 "Cleanup model download failed. Try again later.", "Download cleanup model (about 1.3 GB)",
                                                 "Get shepetal for $4.99…"],
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

        let downloading = top(MenuState(cleanupDownloadMB: 1281, downloadingCleanup: true))
        XCTAssertEqual(downloading.map(\.title), ["Downloading the cleanup model…"],
                       "no download item while it runs, so a second click cannot start a second download")
        XCTAssertFalse(downloading[0].enabled)
        XCTAssertEqual(top(MenuState(cleanupDownloadMB: 1281, cleanupDownloadFailed: true)).map(\.action), [nil, .downloadCleanup],
                       "after a failed download: a grey line, and the item again")
    }

    /// F39 (#30): the keyword model's download is with what needs doing, only while SpeechMenu offers it (speech
    /// recognition there, words in the dictionary, keyword model missing), and greyed out while it runs.
    func testDictionarySupportShowsOnlyWhenOfferedAndGreysOutWhileItDownloads() throws {
        XCTAssertEqual(MenuModel.groups(MenuState()).joined().count, 12, "a normal day keeps the 12 items")

        let offered = MenuModel.contextual(MenuState(dictionarySupport: .offered))
        XCTAssertEqual(offered, [MenuEntry(title: "Download dictionary support (about 100 MB)", action: .downloadDictionarySupport)])
        XCTAssertEqual(MenuModel.groups(MenuState(dictionarySupport: .offered))[0], offered, "at the top")
        let running = MenuModel.contextual(MenuState(dictionarySupport: .downloading))
        XCTAssertEqual(running.map(\.title), ["Downloading dictionary support…"])
        for t in offered.map(\.title) + running.map(\.title) {
            XCTAssertTrue(ModelNameTests.offending("\"\(t)\"").isEmpty, "model name in \(t)")
        }

        let built = { (s: DictionarySupport) -> NSMenuItem? in
            let m = NSMenu()
            MenuModel.build(MenuModel.groups(MenuState(dictionarySupport: s)), into: m, target: self, action: #selector(self.noop(_:)))
            return m.items.first
        }
        XCTAssertEqual(built(.offered)?.isEnabled, true)
        XCTAssertEqual(built(.offered)?.representedObject as? MenuAction, .downloadDictionarySupport)
        XCTAssertEqual(built(.downloading)?.isEnabled, false, "greyed out: a second click starts nothing")

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
        XCTAssertEqual(recent.map(\.title), ["Click to copy", "Send the report today.", "(too short)"])
        XCTAssertTrue(recent[0].header)
        XCTAssertEqual(recent[1].action, .copy("Send the report today."))
        XCTAssertNil(recent[2].action, "nothing to copy")
        XCTAssertEqual(MenuModel.recent([]).map(\.title), ["Nothing yet"])

        let everything = allTitles(Array(MenuModel.groups(busy).joined()))
        XCTAssertFalse(everything.contains { $0.contains("Copy last") }, "Copy last text left the menu")
        XCTAssertEqual(Shortcuts().chord(.copyLast), Shortcuts.defaults[.copyLast], "its shortcut, ⌃⌘C, stays")
        XCTAssertTrue(try AppSource.code("App.swift").contains("case .copyLast: copyLast()"), "and still copies")
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
        XCTAssertFalse(try XCTUnwrap(real.first { $0.title == "Loading on-device speech recognition…" }).isEnabled)
        let past = try XCTUnwrap(real.first { $0.title == "Past meetings" }?.submenu)
        XCTAssertEqual(past.items.first?.representedObject as? MenuAction, .showMeeting("m0"))
        let recent = try XCTUnwrap(real.first { $0.title == "Recent" }?.submenu)
        XCTAssertTrue(recent.items[0].isSectionHeader)
        XCTAssertFalse(recent.items[2].isEnabled, "(too short) is greyed out")

        let updates = { (can: Bool) -> NSMenuItem? in
            let m = NSMenu()
            MenuModel.build(MenuModel.groups(MenuState(canCheckForUpdates: can)), into: m, target: self, action: #selector(self.noop(_:)))
            return m.items.first { $0.title == "Check for Updates…" }
        }
        XCTAssertEqual(updates(true)?.isEnabled, true)
        XCTAssertEqual(updates(false)?.isEnabled, false, "greyed out until an updater can check")
        XCTAssertFalse(NoUpdateChecker().canCheckForUpdates)
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
        XCTAssertEqual(MenuModel.helpCenter.absoluteString, "https://shepetal.backant.io/help")
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
        var state = busy
        state.engineProblem = nil
        state.access = .trial(daysLeft: 3)
        let menu = allTitles(Array(MenuModel.groups(state).joined()))
        for m in moved {
            XCTAssertTrue(m.place.contains(m.window), "\(m.menu) is missing from the window")
            XCTAssertFalse(menu.contains { $0.hasPrefix(m.menu) }, "\(m.menu) is still in the menu")
        }
        XCTAssertTrue(home.contains("AccountSection()"), "the account and trial line are on Home")
        let app = try AppSource.code("App.swift")
        XCTAssertTrue(app.contains("loginItem: loginItem, openDictionary: { [speech] in speech.openDictionary() },"))
        XCTAssertTrue(app.contains("restoreFnKey: { [weak self] in self?.restoreFnKey() },"))
    }

    /// The glue between the app and the model: the state it reads and the actions it performs.
    func testTheAppFeedsTheMenuAndPerformsItsActions() throws {
        let app = try AppSource.code("App.swift")
        for line in ["permissionsMissing: !Permission.missing.isEmpty,", "engineProblem: engine == nil ? engineStatus : nil,",
                     "recordingMeeting: meetings.current != nil,", "pasteLast: tap.router.shortcuts.chord(.pasteLast),",
                     "canCheckForUpdates: updater.canCheckForUpdates)",
                     "cleanupDownloadMB: pipeline?.cleanupToDownload?.megabytes,", "downloadingCleanup: pipeline?.downloadingCleanup == true,",
                     "cleanupDownloadFailed: pipeline?.cleanupDownloadFailed == true,",
                     "case .downloadCleanup: Task { await pipeline?.downloadCleanup() }", "Task { await pipeline?.loadCleanup() }",
                     "case .permissions: showOnboarding()", "case .meeting: meetings.toggle()",
                     "case .showMeeting(let id): if let m = try? meetingFlow?.store.get(id)?.meeting { openTranscript(m) }",
                     "openTranscript = MeetingTranscriptWindow.follow(meetingFlow)",
                     "case .openMeetings: openedHub()?.showMeetings()", "case .checkForUpdates: updater.checkForUpdates()",
                     "case .pasteLast: pasteLast()", "case .helpCenter: NSWorkspace.shared.open(MenuModel.helpCenter)",
                     "case .feedback: NSWorkspace.shared.open(MenuModel.feedback)", "case .quit: NSApp.terminate(nil)"] {
            XCTAssertTrue(app.contains(line), "App.swift: \(line)")
        }
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
