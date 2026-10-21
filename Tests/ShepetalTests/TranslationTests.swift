import AppKit
import ShepetalCore
import Translation
import XCTest
@testable import Shepetal

/// F41: Translate to English. Stub translators and stubbed framework calls only: no test here reaches Apple's
/// translation, shows a window or uses the network.
@MainActor
final class TranslationTests: XCTestCase {
    final class StubTranslator: Translator {
        var result: Result<String, TranslateError> = .success("Hello, how are you today?")
        var calls: [(text: String, source: String, target: String)] = []
        var toDownload: [String] = []
        var downloads: [String] = []

        func translate(_ text: String, from source: String, to target: String) async throws -> String {
            calls.append((text, source, target))
            return try result.get()
        }

        func download(_ language: String) async -> String {
            downloads.append(language)
            return "ready"
        }
    }

    let german = "Hallo, wie geht es dir heute?"
    let chinese = "你好，今天你怎么样？我们明天见。"
    let japanese = "こんにちは、今日はお元気ですか？また明日会いましょう。"
    let thai = "สวัสดีครับ วันนี้คุณเป็นอย่างไรบ้าง"
    let norwegian = "Hei, hvordan har du det i dag? Vi sees i morgen."

    func step(_ translator: Translator?, on: Bool = true, languages: [String] = []) -> TranslateStep {
        TranslateStep(isOn: { on }, languages: { languages }, translator: translator)
    }

    // What lands is the English; the spoken language goes in as the source.
    func testTheTranslationIsWhatGetsInserted() async {
        let stub = StubTranslator()
        let out = await step(stub)(german)
        XCTAssertEqual(out.text, "Hello, how are you today?")
        XCTAssertNil(out.hint)
        XCTAssertEqual(stub.calls.map(\.text), [german])
        XCTAssertEqual(stub.calls.map(\.source), ["de"])
        XCTAssertEqual(stub.calls.map(\.target), ["en"])
    }

    // Off by default, and off, nothing is handed to a translator: the German lands as it was said.
    func testOffLeavesTheTextAlone() async throws {
        try XCTSkipIf(UserDefaults.standard.object(forKey: Translate.key) != nil, "set in this test runner's defaults")
        XCTAssertFalse(TranslateStep(translator: nil).isOn(), "off by default")
        let stub = StubTranslator()
        let out = await step(stub, on: false)(german)
        XCTAssertEqual(out.text, german)
        XCTAssertNil(out.hint)
        XCTAssertTrue(stub.calls.isEmpty)
    }

    // Source equal to target skips the step: English is never sent off to become English, and an empty
    // dictation or one whose language cannot be told stays as it is, without a hint. With Automatic a short one
    // cannot be told: "Redis." reads as French and "x" as Slovak, and neither must ask for a download. Nor
    // may jargon the recognizer is unsure of: "Redis Postgres Kubernetes" reads as German at 0.43. English stays
    // English among Chinese and Norwegian, and when only German is chosen it is not sent off as German.
    func testEnglishSkipsTheStep() async {
        let stub = StubTranslator()
        for (text, languages) in [("Send the report to Anna by Friday.", [String]()), ("Okay, see you tomorrow.", ["en-US", "de"]),
                                  ("Okay, see you tomorrow.", ["zh", "no", "en"]), ("Send the report to Anna by Friday.", ["de"]),
                                  ("", []), ("42", []), ("Redis.", []), ("x", []), ("Ship it now", []), ("你好", []),
                                  ("Redis Postgres Kubernetes", []), ("Kafka Redis Mongo Elastic", [])] {
            let out = await step(stub, languages: languages)(text)
            XCTAssertEqual(out.text, text)
            XCTAssertNil(out.hint, text)
        }
        XCTAssertTrue(stub.calls.isEmpty, "\(stub.calls.map(\.text))")
    }

    // A short dictation is easy to misread, so the chosen languages decide: "Gift" is German for poison.
    func testTheChosenLanguagesPinTheSpokenOne() {
        XCTAssertEqual(Translate.spokenLanguage("Gift", among: ["de"]), "de")
        XCTAssertEqual(Translate.spokenLanguage("Gift", among: ["en"]), "en")
        XCTAssertNil(Translate.spokenLanguage("Gift", among: []), "Automatic: one word is too short to tell")
        XCTAssertNil(Translate.spokenLanguage("Danke schön", among: []), "Automatic: under 3 words")
        XCTAssertEqual(Translate.spokenLanguage("Danke schön", among: ["de", "en"]), "de", "chosen: no word count")
        XCTAssertEqual(Translate.spokenLanguage("Bonjour à tous, merci d'être venus si nombreux.", among: []), "fr")
        XCTAssertEqual(Translate.spokenLanguage("Bonjour à tous, merci d'être venus si nombreux.", among: ["fr-CA", "en"]), "fr")
        XCTAssertEqual(Translate.spokenLanguage("Send the report to Anna by Friday.", among: ["de"]), "en", "a sure guess beats the pin")
        XCTAssertNil(Translate.spokenLanguage("Tere, kuidas sul täna läheb? Näeme homme.", among: ["et"]),
                     "but not for a language the recognizer cannot tell: it reads this Estonian as Finnish at 0.95")
        // No spaces between words, and the recognizer's own tags for whisper's "zh" and "no".
        XCTAssertEqual(Translate.spokenLanguage(chinese, among: []), "zh-Hans", "Automatic: 7 words, not 1")
        XCTAssertEqual(Translate.spokenLanguage(japanese, among: []), "ja")
        XCTAssertEqual(Translate.spokenLanguage(thai, among: []), "th")
        XCTAssertEqual(Translate.spokenLanguage(chinese, among: ["zh"]), "zh-Hans")
        XCTAssertEqual(Translate.spokenLanguage("你好嗎？今天過得怎麼樣？", among: ["zh", "en"]), "zh-Hant")
        XCTAssertEqual(Translate.spokenLanguage("你好", among: ["zh", "en"]).map { languageCodes([$0]) }, ["zh"], "chosen: short is fine")
        XCTAssertEqual(Translate.spokenLanguage(japanese, among: ["ja"]), "ja")
        XCTAssertEqual(Translate.spokenLanguage(norwegian, among: ["no"]), "nb")
        XCTAssertEqual(Translate.spokenLanguage(norwegian, among: ["no", "en"]), "nb")
        XCTAssertEqual(Translate.spokenLanguage("Hei", among: ["no", "en"]), "nb")
    }

    // Chinese, Japanese and Thai reach the translator, and so does Norwegian; Apple has no Norwegian to English,
    // so 🤫 says that rather than nothing.
    func testTextWithoutSpacesAndNorwegianAreTranslatedOrSayWhy() async {
        let stub = StubTranslator()
        for (text, languages) in [(chinese, [String]()), (chinese, ["zh"]), (japanese, []), (thai, []), (norwegian, ["no", "en"])] {
            let out = await step(stub, languages: languages)(text)
            XCTAssertEqual(out.text, "Hello, how are you today?", text)
        }
        XCTAssertEqual(stub.calls.map(\.source), ["zh-Hans", "zh-Hans", "ja", "th", "nb"])
        let unsupported = StubTranslator()
        unsupported.result = .failure(.unsupported)
        let out = await step(unsupported, languages: ["no"])(norwegian)
        XCTAssertEqual(out.text, norwegian)
        XCTAssertEqual(out.hint, "Not translated: on-device translation has no \(Translate.name("nb")) to English")
    }

    // A failure inserts what was said, and 🤫 says why in plain words that name the language and no model.
    func testFailureFallsBackToTheOriginalWithAHint() async {
        let german = Translate.name("de")
        let cases: [(TranslateError, String)] = [
            (.notDownloaded, "Not translated: download \(german) for translation in 🤫 > Languages"),
            (.unsupported, "Not translated: on-device translation has no \(german) to English"),
            (.failed, "Not translated: on-device translation failed"),
        ]
        for (error, hint) in cases {
            let stub = StubTranslator()
            stub.result = .failure(error)
            let out = await step(stub)(self.german)
            XCTAssertEqual(out.text, self.german, "\(error)")
            XCTAssertEqual(out.hint, hint)
        }
        let empty = StubTranslator()
        empty.result = .success("")
        let out = await step(empty)(self.german)
        XCTAssertEqual(out.text, self.german, "an empty translation would paste nothing")
        XCTAssertEqual(out.hint, "Not translated: on-device translation failed")
        let before15 = await step(nil)(self.german)
        XCTAssertEqual(before15.text, self.german)
        XCTAssertEqual(before15.hint, "Not translated: on-device translation needs macOS 15")
    }

    // MARK: Apple's translation, its calls stubbed

    // A language that is not downloaded is never fetched during a dictation (that would put up the system's
    // download prompt): no session opens, and the 🤫 Languages menu offers it, once.
    func testANotDownloadedLanguageIsOfferedNotFetched() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Apple's translation needs macOS 15") }
        let t = OnDeviceTranslator()
        var sessions = 0
        t.status = { _, _ in .supported }
        t.session = { _, _, _, _ in sessions += 1; return "x" }
        for _ in 0..<2 {
            do {
                _ = try await t.translate(german, from: "de", to: "en")
                XCTFail("not downloaded: nothing to translate with")
            } catch { XCTAssertEqual(error as? TranslateError, .notDownloaded) }
        }
        XCTAssertEqual(sessions, 0)
        XCTAssertEqual(t.toDownload, ["de"])

        t.status = { _, _ in .unsupported }
        do {
            _ = try await t.translate("Shalom", from: "he", to: "en")
            XCTFail("unsupported")
        } catch { XCTAssertEqual(error as? TranslateError, .unsupported) }
        XCTAssertEqual(t.toDownload, ["de"], "a pair Apple does not have is not offered for download")
        XCTAssertEqual(sessions, 0)
    }

    // A downloaded pair translates in the invisible window (no message) and with the timeout, so a session
    // that never comes cannot hold the dictation. Any failure there is reported as failed.
    func testAnInstalledPairTranslatesInTheHiddenWindow() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Apple's translation needs macOS 15") }
        let t = OnDeviceTranslator()
        var asked: [(TranslationSession.Configuration, String?, Duration?)] = []
        t.status = { from, to in from.languageCode == "de" && to.languageCode == "en" ? .installed : .supported }
        t.session = { pair, message, timeout, _ in asked.append((pair, message, timeout)); return "Hello" }
        let english = try await t.translate(german, from: "de", to: "en")
        XCTAssertEqual(english, "Hello")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0.source?.languageCode, "de")
        XCTAssertEqual(asked.first?.0.target?.languageCode, "en")
        XCTAssertNil(asked.first?.1, "a dictation shows no window")
        XCTAssertEqual(asked.first?.2, OnDeviceTranslator.timeout)
        XCTAssertEqual(OnDeviceTranslator.timeout, .seconds(10))

        t.session = { _, _, _, _ in throw CocoaError(.userCancelled) }
        do {
            _ = try await t.translate(german, from: "de", to: "en")
            XCTFail("the session failed")
        } catch { XCTAssertEqual(error as? TranslateError, .failed) }
    }

    // Esc while a dictation waits for its session lets the dictation go at once, not after the 10 s timeout. The
    // host cannot run here without showing its panel and reaching Apple's translation, so this pins the source.
    func testEscDoesNotWaitForTheSession() throws {
        let run = try AppSource.body(of: "func run(", in: AppSource.code("Translation.swift"))
        XCTAssertTrue(run.contains("withTaskCancellationHandler"))
        XCTAssertTrue(run.contains("} onCancel: {\n            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }"))
    }

    // The download is the user's: a shepetal window that says what it is for, no timeout while the system asks,
    // the item hidden while it runs, and the answer checked afterwards (a "no" may come without an error).
    func testDownloadAsksInAVisibleWindowAndSaysHowItWent() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Apple's translation needs macOS 15") }
        let t = OnDeviceTranslator()
        var installed = false
        t.status = { _, _ in installed ? .installed : .supported }
        t.session = { _, _, _, _ in "" }
        _ = try? await t.translate(german, from: "de", to: "en")
        XCTAssertEqual(t.toDownload, ["de"])

        var asked: [(String?, Duration?, [String])] = []
        t.session = { [t] _, message, timeout, _ in asked.append((message, timeout, t.toDownload)); return "" }
        let name = Translate.name("de")
        let no = await t.download("de")
        XCTAssertEqual(no, "\(name) was not downloaded for translation")
        XCTAssertEqual(t.toDownload, ["de"], "still offered after a no")

        t.session = { [t] _, message, timeout, _ in asked.append((message, timeout, t.toDownload)); installed = true; return "" }
        let yes = await t.download("de")
        XCTAssertEqual(yes, "\(name) is ready for translation")
        XCTAssertEqual(t.toDownload, [], "downloaded: the item leaves the menu")
        XCTAssertEqual(asked.map(\.0), Array(repeating: "Getting \(name) ready for on-device translation…", count: 2))
        XCTAssertEqual(asked.map(\.1), [nil, nil], "the user takes as long as they like")
        XCTAssertEqual(asked.map(\.2), [[], []], "hidden while it runs: a second click cannot start a second download")
    }

    // Rule 8: the window a dictation's translation runs in can never take focus or a click; the download's is a
    // plain shepetal window. Built, never shown.
    func testTheDictationWindowCannotTakeFocus() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Apple's translation needs macOS 15") }
        _ = NSApplication.shared
        let hidden = TranslationHost(message: nil).window
        XCTAssertTrue(hidden is NSPanel)
        XCTAssertTrue(hidden.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(hidden.styleMask.contains(.titled))
        XCTAssertFalse(hidden.canBecomeKey)
        XCTAssertFalse(hidden.canBecomeMain)
        XCTAssertTrue(hidden.ignoresMouseEvents)
        XCTAssertEqual(hidden.alphaValue, 0)
        XCTAssertFalse(hidden.isVisible)
        let download = TranslationHost(message: "Getting German ready for on-device translation…").window
        XCTAssertEqual(download.title, "shepetal")
        XCTAssertTrue(download.styleMask.contains(.titled))
        XCTAssertFalse(download.isVisible, "shown only when the download runs")
    }

    // MARK: the 🤫 Languages menu

    // Translate to English sits first in Languages (the language list below it is long), off by default. Turned
    // on, it offers each language a dictation needed; before macOS 15 neither item is there (never a grey item,
    // #207). A throwaway defaults suite: the user's settings are never read or changed.
    func testTheLanguagesMenuHasTheSettingAndTheDownloads() async throws {
        let suite = "shepetal-translate-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = SpeechMenu()
        menu.translateDefaults = defaults
        let stub = StubTranslator()
        stub.toDownload = ["de"]
        var notices: [String] = []
        menu.translator = stub
        menu.notice = { notices.append($0) }
        func items() throws -> [NSMenuItem] { try XCTUnwrap(menu.languagesItem().submenu).items }

        let toggle = try XCTUnwrap(try items().first)
        XCTAssertEqual(toggle.title, "Translate to English")
        XCTAssertEqual(toggle.state, .off, "off by default")
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertFalse(try items().contains { $0.title.hasPrefix("Download") }, "off: nothing to download")
        XCTAssertTrue(click(toggle))
        XCTAssertTrue(defaults.bool(forKey: Translate.key))

        let on = try items()
        XCTAssertEqual(on.first { $0.title == "Translate to English" }?.state, .on)
        XCTAssertEqual(on.map(\.title).prefix(4), ["Translate to English", "Download \(Translate.name("de")) for translation…", "", "Automatic"])
        let download = on[1]
        XCTAssertTrue(download.isEnabled)
        XCTAssertTrue(click(download))
        for _ in 0..<100 where notices.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(stub.downloads, ["de"])
        XCTAssertEqual(notices, ["ready"], "🤫 says how it went")

        XCTAssertTrue(click(try XCTUnwrap(try items().first { $0.title == "Translate to English" })))
        XCTAssertFalse(defaults.bool(forKey: Translate.key), "a second click turns it off")

        menu.translator = nil
        XCTAssertEqual(try items().first?.title, "Automatic", "before macOS 15: not there at all")
        XCTAssertFalse(try items().contains { $0.title == "Translate to English" || $0.title.hasPrefix("Download") })
    }

    /// What a click on the item does: its action on its target.
    private func click(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let target = item.target, target.responds(to: action) else { return false }
        _ = target.perform(action, with: item)
        return true
    }
}
