import AppKit
import NaturalLanguage
import ShepetalCore
import SwiftUI
import Translation

/// F41: Translate to English. What was said stays in the row's raw text and the English goes in its text, and only
/// Apple's on-device translation (macOS 15 and later) translates. Off by default.
@MainActor
protocol Translator: AnyObject {
    /// `text` from `source` into `target` (language tags). Throws `TranslateError`; the 🤫 hint says why.
    func translate(_ text: String, from source: String, to target: String) async throws -> String
    /// The languages a dictation needed that are not downloaded yet: the 🤫 Languages menu offers each.
    var toDownload: [String] { get }
    /// User action only (the 🤫 menu). Returns the notice for 🤫.
    func download(_ language: String) async -> String
}

enum TranslateError: Error, Equatable { case notDownloaded, unsupported, failed, needsMacOS15 }

@MainActor
enum Translate {
    /// The 🤫 Languages menu's Translate to English (UserDefaults, Bool, off by default).
    static let key = "translateToEnglish"
    static let target = "en"

    /// Apple's on-device translation. nil before macOS 15, where the menu has no Translate to English.
    static var onDevice: Translator? {
        if #available(macOS 15, *) { return OnDeviceTranslator.shared }
        return nil
    }

    /// The language the text is in: one of the chosen ones when there are any. With Automatic, only a sure guess
    /// on at least 3 words, F12's bar (it read "Redis." as French). nil when the recognizer cannot tell.
    static func spokenLanguage(_ text: String, among languages: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        let chosen = languageCodes(languages)
        recognizer.languageConstraints = chosen.map { NLLanguage($0) }
        recognizer.processString(text)
        guard chosen.isEmpty else { return recognizer.dominantLanguage?.rawValue }
        guard text.split(whereSeparator: \.isWhitespace).count >= 3,
              let (language, p) = recognizer.languageHypotheses(withMaximum: 1).first, p >= 0.9 else { return nil }
        return language.rawValue
    }

    static func name(_ language: String) -> String { Locale.current.localizedString(forIdentifier: language) ?? language }

    /// Next to 🤫 when the text stays as it was said. Names no model.
    static func hint(_ error: TranslateError, _ language: String) -> String {
        switch error {
        case .notDownloaded: "Not translated: download \(name(language)) for translation in 🤫 > Languages"
        case .unsupported: "Not translated: on-device translation has no \(name(language)) to English"
        case .failed: "Not translated: on-device translation failed"
        case .needsMacOS15: "Not translated: on-device translation needs macOS 15"
        }
    }
}

/// F41's step, after the text step (`Pipeline.finishText`, with F42's "press enter" already taken off) and before
/// the text is fitted to the cursor, for dictation and History's re-transcribe alike. Tests set each part.
@MainActor
struct TranslateStep {
    var isOn: () -> Bool = { UserDefaults.standard.bool(forKey: Translate.key) }
    /// The 🤫 Languages choice: when there is one, the text is in one of those languages.
    var languages: () -> [String] = { UserDefaults.standard.stringArray(forKey: "languages") ?? [] }
    var translator: Translator? = Translate.onDevice

    /// The text to insert, and the hint for 🤫 when it stays as it was said. English stays as it is, and so does
    /// text whose language cannot be told.
    func callAsFunction(_ text: String) async -> (text: String, hint: String?) {
        guard isOn(), !text.isEmpty, let source = Translate.spokenLanguage(text, among: languages()),
              languageCodes([source]) != [Translate.target] else { return (text, nil) }
        guard let translator else { return (text, Translate.hint(.needsMacOS15, source)) }
        do {
            let translated = try await translator.translate(text, from: source, to: Translate.target)
            return translated.isEmpty ? (text, Translate.hint(.failed, source)) : (translated, nil)
        } catch {
            return (text, Translate.hint(error as? TranslateError ?? .failed, source))
        }
    }
}

/// Apple's Translation framework, on this Mac. Its session comes only from SwiftUI's `.translationTask` on macOS
/// 15 (its own initializer needs macOS 26), so each request runs in a view in a window of its own. A language is
/// never downloaded during a dictation: that is the 🤫 menu's Download item, which the system asks about.
/// ponytail: one window per request; keep one if opening it shows up in the latency.
@available(macOS 15, *)
@MainActor
final class OnDeviceTranslator: Translator {
    static let shared = OnDeviceTranslator()
    /// A sentence takes well under a second; a session that never comes must not hold the dictation.
    static let timeout: Duration = .seconds(10)

    /// Seams, so tests reach neither the framework nor a window.
    var status: @MainActor (Locale.Language, Locale.Language) async -> LanguageAvailability.Status = {
        await LanguageAvailability().status(from: $0, to: $1)
    }
    /// Runs `work` with a session. `message` nil: in a window nobody sees; else a shepetal window that says it.
    var session: @MainActor (_ pair: TranslationSession.Configuration, _ message: String?, _ timeout: Duration?,
                  _ work: @escaping (TranslationSession) async throws -> String) async throws -> String = {
        try await TranslationHost(message: $1).run($0, timeout: $2, $3)
    }

    private var offered: [String] = []
    private var downloading: String?
    var toDownload: [String] { offered.filter { $0 != downloading } }  // hidden while it downloads: one click, one download

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        switch await status(from, to) {
        case .installed: break
        case .supported:
            if !offered.contains(source) { offered.append(source) }
            throw TranslateError.notDownloaded
        default: throw TranslateError.unsupported
        }
        do {
            return try await session(.init(source: from, target: to), nil, Self.timeout) { try await $0.translate(text).targetText }
        } catch {
            NSLog("shepetal: translation: %@", String(describing: error))  // the detail goes to the log
            throw TranslateError.failed
        }
    }

    func download(_ language: String) async -> String {
        guard downloading == nil else { return "Wait for the download that is running" }
        downloading = language
        defer { downloading = nil }
        let name = Translate.name(language)
        let from = Locale.Language(identifier: language), to = Locale.Language(identifier: Translate.target)
        do {
            _ = try await session(.init(source: from, target: to), "Getting \(name) ready for on-device translation…", nil) {
                try await $0.prepareTranslation()
                return ""
            }
        } catch { NSLog("shepetal: translation download: %@", String(describing: error)) }
        // Asked again: the user may have said no to the system's prompt without an error.
        guard await status(from, to) == .installed else { return "\(name) was not downloaded for translation" }
        offered.removeAll { $0 == language }
        return "\(name) is ready for translation"
    }
}

/// One request's window, where `.translationTask` hands over a session. For a dictation it is invisible, cannot be
/// clicked and never becomes key, so the window the user dictates into keeps focus (rule 8). For a download it is
/// a small shepetal window, so the system's download prompt has somewhere to show.
@available(macOS 15, *)
@MainActor
final class TranslationHost: ObservableObject {
    @Published fileprivate var configuration: TranslationSession.Configuration?
    let window: NSWindow
    private let visible: Bool
    private var work: ((TranslationSession) async throws -> String)?
    private var waiting: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?

    init(message: String?) {
        visible = message != nil
        if visible {
            window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.title = "shepetal"
        } else {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window = panel
        }
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: TranslationHostView(host: self, message: message))
        window.contentView = view
        if visible { window.setContentSize(view.fittingSize) }
    }

    /// `work`'s result, once SwiftUI has handed over a session for `pair`. Fails after `timeout`, or when the
    /// user closes the window.
    func run(_ pair: TranslationSession.Configuration, timeout: Duration?,
             _ work: @escaping (TranslationSession) async throws -> String) async throws -> String {
        let closed = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failure(TranslateError.failed)) }
        }
        defer {
            NotificationCenter.default.removeObserver(closed)
            window.contentView = nil  // the view holds this host: let both go
            window.close()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            self.work = work
            if let timeout {
                timer = Task { [weak self] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    self?.finish(.failure(TranslateError.failed))
                }
            }
            if visible {
                NSApp.activate(ignoringOtherApps: true)  // the user asked for it in the 🤫 menu
                window.center()
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()  // a non-activating panel: shepetal does not become the active app
            }
            configuration = pair
        }
    }

    fileprivate func perform(_ session: TranslationSession) async {
        guard let work else { return }
        self.work = nil
        do { finish(.success(try await work(session))) } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<String, Error>) {
        timer?.cancel()
        waiting?.resume(with: result)
        waiting = nil
    }
}

@available(macOS 15, *)
private struct TranslationHostView: View {
    @ObservedObject var host: TranslationHost
    let message: String?

    var body: some View {
        Group {
            if let message { Text(message).padding(24).fixedSize() } else { Color.clear.frame(width: 1, height: 1) }
        }
        .translationTask(host.configuration) { await host.perform($0) }
    }
}
