import AppKit
import Combine
import SwiftUI
import XCTest
import ShepetalCore
@testable import Shepetal

/// A recognizer that always fails, like whisper.cpp that is not installed or a model that cannot run.
private final class BrokenEngine: SpeechEngine {
    let name = SpeechModel.parakeetV3.rawValue
    let readsWav = false
    func transcribe(_ samples: [Float], wav: URL) async throws -> String { throw SpeechError("could not run") }
}

/// The shepetal window's buttons (issue #38), below the SwiftUI views: History's search, Archive and Show
/// archived, Re-transcribe, Settings' Recordings choice, the Dictionary tab (F91) and the input settings it
/// mirrors from the 🤫 menu. Each test gets a temp data dir and a private pasteboard; nothing is put on
/// screen, takes focus, touches the clipboard or reads Pavel's dictionary.txt. Copy is not called here while
/// HubModel.copy still writes NSPasteboard.general; its test comes with the wiring that routes it through the pipeline.
@MainActor
final class HubTests: XCTestCase {
    private var root: URL!
    private var pasteboard: NSPasteboard!
    private var pipeline: Pipeline!
    private var stored = Retention.keep
    private let t0 = Date(timeIntervalSince1970: 1_792_508_400)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
        pipeline = try Pipeline(root: root, pasteboard: pasteboard)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    /// Like App: the Recordings choice is stored and applied to the audio folder at once.
    private func hub(engine: SpeechEngine? = nil) -> HubModel {
        HubModel(pipeline: pipeline, engine: { engine }, status: { ("", false) },
                 retention: { [unowned self] in stored },
                 setRetention: { [unowned self] in stored = $0; _ = try? pipeline.store.applyRetention($0) },
                 openPermissions: {}, loginItem: LoginItem(say: { _ in }), openDictionary: {}, restoreFnKey: {},
                 openWhatsNew: {}, notices: { [] })
    }

    /// A dictation with its WAV kept, made `minutesAgo` before t0 (History lists the newest first).
    @discardableResult
    private func dictation(_ text: String, minutesAgo: Double = 0) throws -> HistoryEntry {
        let id = UUID().uuidString
        let wav = try pipeline.store.save([Float](repeating: 0.1, count: 16_000), id: id)
        let e = HistoryEntry(id: id, createdAt: t0.addingTimeInterval(-minutesAgo * 60), outcome: .inserted,
                             audioPath: wav.path, durationMs: 1000, model: SpeechModel.parakeetV3.rawValue,
                             rawText: text, text: text, app: "TextEdit")
        try pipeline.history.add(e)
        return e
    }

    // MARK: History

    /// M-HUB-2: typing in Search lists only the matching dictations, and clearing it brings all of them back.
    func testSearchReloadsAsYouType() throws {
        let report = try dictation("Send the quarterly report today", minutesAgo: 2)
        let dentist = try dictation("Call the dentist at 100% volume", minutesAgo: 1)
        let model = hub()
        model.reload()
        XCTAssertEqual(model.rows.map(\.id), [dentist.id, report.id], "newest first")

        model.query = "QUARTERLY"
        XCTAssertEqual(model.rows.map(\.id), [report.id], "case does not matter")
        model.query = "100%"
        XCTAssertEqual(model.rows.map(\.id), [dentist.id], "% is the character, not a wildcard")
        model.query = ""
        XCTAssertEqual(model.rows.map(\.id), [dentist.id, report.id])
    }

    /// M-HUB-5: an archived dictation leaves the list, Show archived brings it back, and Unarchive keeps it.
    func testArchiveHidesARowUntilShowArchived() throws {
        let kept = try dictation("keep me", minutesAgo: 2)
        let old = try dictation("archive me", minutesAgo: 1)
        let model = hub()
        model.reload()

        model.setArchived(old, true)
        XCTAssertEqual(model.rows.map(\.id), [kept.id], "Archive takes it out of the list")
        model.showArchived = true
        XCTAssertEqual(model.rows.map(\.id), [old.id, kept.id])
        XCTAssertEqual(model.rows.first?.archived, true, "marked archived, so the button reads Unarchive")

        model.setArchived(try XCTUnwrap(model.rows.first), false)
        model.showArchived = false
        XCTAssertEqual(model.rows.map(\.id), [old.id, kept.id], "Unarchive puts it back for good")
    }

    /// M-HUB-3 and M-HUB-6: Delete recordings after 24 hours is stored, runs at once, and the list redraws, so
    /// an old row shows "recording deleted" with Play and Re-transcribe off while its text stays.
    func testRetentionChangeDeletesOldRecordingsAndRedrawsTheList() throws {
        let old = try dictation("from last week", minutesAgo: 1)
        let fresh = try dictation("from just now")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)],
                                              ofItemAtPath: old.audioPath)
        let model = hub()
        model.reload()
        XCTAssertTrue(model.rows.allSatisfy { $0.canReplay() })

        var redraws = 0
        let watch = model.objectWillChange.sink { redraws += 1 }
        defer { watch.cancel() }
        model.changeRetention(.delete24h)
        XCTAssertEqual(model.retention(), .delete24h, "the picker reads back the new choice")
        XCTAssertGreaterThan(redraws, 0, "History redraws, so the old row says recording deleted right away")
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        XCTAssertEqual(rows[old.id]?.canReplay(), false)
        XCTAssertEqual(rows[old.id]?.text, "from last week", "only the audio goes, never the text")
        XCTAssertEqual(rows[fresh.id]?.canReplay(), true, "a recording under 24 hours old stays")
    }

    /// M-HUB-4: the model already running is offered first and needs nothing loaded; it is not offered twice.
    func testRetryChoicesListTheCurrentEngineFirst() {
        let choices = hub(engine: BrokenEngine()).retryChoices
        XCTAssertTrue(choices.first?.title.hasSuffix("(current)") == true, "\(choices.map(\.title))")
        XCTAssertNil(choices.first?.model, "the current engine is used as it is")
        XCTAssertFalse(choices.dropFirst().contains { $0.model?.rawValue == SpeechModel.parakeetV3.rawValue })
        XCTAssertFalse(choices.contains { $0.title.lowercased().contains("parakeet") || $0.title.contains("whisper") },
                       "titles name the engine kind, never the model")
        XCTAssertFalse(hub().retryChoices.contains { $0.title.hasSuffix("(current)") },
                       "with no engine loaded there is no current choice")
    }

    /// M-HUB-4: a re-transcribe that fails says so and leaves the row exactly as it was, audio included.
    func testFailedRetranscribeLeavesTheRowUnchanged() async throws {
        let e = try dictation("what I said first")
        let model = hub(engine: BrokenEngine())
        model.reload()

        model.retry(e, with: nil)
        XCTAssertEqual(model.busy, e.id, "Re-transcribe is greyed out on every row meanwhile")
        let deadline = Date().addingTimeInterval(10)
        while model.busy != nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(model.busy, "the re-transcribe never finished")

        XCTAssertTrue(model.message.hasPrefix("Re-transcribe failed: "), model.message)
        XCTAssertEqual(try pipeline.history.search("").first, e, "time, text, model and audio stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.audioPath), "raw audio is always kept")
    }

    // MARK: Dictionary tab (F91)

    private var dictionaryURL: URL { pipeline.dictionary }
    private func file() throws -> String { try String(contentsOf: dictionaryURL, encoding: .utf8) }

    /// What dictation reads (Vocabulary.load on the same file) is exactly what the tab added.
    func testDictionaryAddWritesWordsAndReplacementsDictationApplies() throws {
        let model = DictionaryModel(url: dictionaryURL, editAsText: {})
        model.reload()
        XCTAssertEqual(model.entries, [])

        XCTAssertTrue(model.add("  GitHub "))
        XCTAssertTrue(model.add("btw", replacement: "by the way"))
        XCTAssertEqual(try file(), Vocabulary.header + "GitHub\nbtw => by the way\n")
        XCTAssertEqual(model.entries.map(\.line), ["GitHub", "btw => by the way"], "the list is the file")
        XCTAssertEqual(Vocabulary.load(dictionaryURL).apply("push to github btw"), "push to GitHub by the way")
        let mode = try FileManager.default.attributesOfItem(atPath: dictionaryURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "personal words stay owner-only")
    }

    /// The tab edits the file dictation reads: the next dictation's text has the word as written in the tab.
    func testAWordAddedInTheTabAppliesToTheNextDictation() async throws {
        let model = DictionaryModel(url: pipeline.dictionary, editAsText: {})
        model.add("Kubernetes")
        model.add("omw", replacement: "on my way")
        let text = await pipeline.finishText("deploying to kubernetes, omw").text
        XCTAssertTrue(text.contains("Kubernetes") && text.contains("on my way"), text)
        XCTAssertFalse(text.contains("omw"), text)
    }

    /// Adding words that are already there changes that entry, so the same words never fire twice.
    func testDictionaryAddOfTheSameWordsChangesTheEntryAndKeepsItsStar() throws {
        let model = DictionaryModel(url: dictionaryURL, editAsText: {})
        model.add("btw", replacement: "by the way")
        model.toggleStar(try XCTUnwrap(model.entries.first))
        XCTAssertTrue(model.add("BTW", replacement: "between"))
        XCTAssertEqual(model.entries, [Vocabulary.Entry(spoken: "BTW", written: "between", starred: true)])
    }

    func testDictionaryStarAndRemoveChangeOnlyTheirLine() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# work\nGitHub\nKubernetes\n".write(to: dictionaryURL, atomically: true, encoding: .utf8)
        let model = DictionaryModel(url: dictionaryURL, editAsText: {})
        model.reload()

        model.toggleStar(model.entries[1])
        XCTAssertEqual(try file(), "# work\nGitHub\n*Kubernetes\n", "the star goes first in the model hint")
        XCTAssertEqual(Vocabulary.load(dictionaryURL).promptTerms, ["Kubernetes", "GitHub"])
        model.toggleStar(model.entries[1])
        XCTAssertEqual(try file(), "# work\nGitHub\nKubernetes\n")

        model.remove(model.entries[0])
        XCTAssertEqual(try file(), "# work\nKubernetes\n", "the user's comment stays")
        XCTAssertEqual(model.entries.map(\.written), ["Kubernetes"])
    }

    /// A blank field, a comment or two lines pasted at once is not one entry, and nothing is written.
    func testDictionaryRefusesWhatIsNotOneEntry() {
        let model = DictionaryModel(url: dictionaryURL, editAsText: {})
        for words in ["", "   ", "# note", "one\ntwo", "=> x"] {
            XCTAssertFalse(model.add(words), words)
        }
        XCTAssertFalse(model.add("btw", replacement: "\n"), "a replacement of nothing is not an entry")
        XCTAssertEqual(model.message, "Type one word or phrase")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dictionaryURL.path), "no file appears for a refused add")
    }

    /// Edit as text… and the tab work on the same file: a line removed in the editor is not written back.
    func testDictionaryNeverWritesOverAnEditMadeInTheTextFile() throws {
        var opened = 0
        let model = DictionaryModel(url: dictionaryURL, editAsText: { opened += 1 })
        model.add("GitHub")
        model.add("Kubernetes")
        model.editAsText()
        XCTAssertEqual(opened, 1, "Edit as text… opens dictionary.txt (SpeechMenu.openDictionary in the app)")
        let stale = model.entries[0]
        try "Kubernetes\nPostgres\n".write(to: dictionaryURL, atomically: true, encoding: .utf8)  // the editor's save

        model.toggleStar(stale)
        XCTAssertEqual(try file(), "Kubernetes\nPostgres\n", "the editor's version wins")
        XCTAssertEqual(model.entries.map(\.written), ["Kubernetes", "Postgres"], "the tab shows the file again")
        XCTAssertEqual(model.message, "dictionary.txt was changed elsewhere. This is what it holds now.")
    }

    // MARK: Settings: the 🤫 menu's input settings (F91)

    /// The Settings tab's Microphone and Languages buttons open the very menus the 🤫 menu shows, built fresh
    /// at each click, and Shortcuts… opens the shortcuts window. The view is laid out off screen.
    func testInputSettingsOpenTheMenusOwnControllers() throws {
        _ = NSApplication.shared
        let device = MicDevice(uid: "test-usb-mic", name: "Test USB Mic", transport: .usb)
        let mic = Mic(recorder: DeadRecorder(), inputs: { [device] })
        var languageBuilds = 0, shortcuts = 0
        let input = HubInput(microphone: mic.menuItem,
                             languages: { languageBuilds += 1; return SpeechMenu().languagesItem() },
                             openShortcuts: { shortcuts += 1 })
        let view = NSHostingView(rootView: Form { HubInputSettings(input: input) }.formStyle(.grouped))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        view.layoutSubtreeIfNeeded()

        let buttons = allViews(view).compactMap { $0 as? NSButton }.compactMap { $0.target as? MenuPopUpButton.Coordinator }
        XCTAssertEqual(buttons.count, 2, "Microphone and Languages")
        let menus = buttons.map { $0.menu?.items.map(\.title) ?? [] }
        let micMenu = try XCTUnwrap(menus.first { $0.contains("Test USB Mic") }, "\(menus)")
        XCTAssertEqual(micMenu, try XCTUnwrap(mic.menuItem().submenu).items.map(\.title))
        XCTAssertTrue(micMenu.contains("Prefer Test USB Mic"), "\(micMenu)")
        XCTAssertEqual(menus.first { !$0.contains("Test USB Mic") }?.first, "Automatic", "the Languages menu")
        _ = buttons.map { $0.menu }
        XCTAssertEqual(languageBuilds, 2, "each click builds the menu again, so its ticks are current")
        XCTAssertEqual(shortcuts, 0)
        input.openShortcuts()
        XCTAssertEqual(shortcuts, 1)
    }

    private func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
}
