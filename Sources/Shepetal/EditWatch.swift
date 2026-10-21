import AppKit
import ShepetalCore

/// F26: after a paste that landed, watch the field it went into for the user's fix of a misheard word. It only reads:
/// focus is never moved (rule 8), and nothing is written to any app. It stops after `window`, when focus leaves the
/// pasted element, at the next dictation, on a secure text field and while Secure Input is on.
@MainActor
final class EditWatch {
    enum End: Equatable { case timeout, focusLeft, nextDictation, secure }

    /// The focused element and what it holds. Tests pass a fake; the app passes `Reader.ax`.
    struct Reader {
        var focused: () -> AXUIElement?
        var isSecure: (AXUIElement) -> Bool
        var text: (AXUIElement) -> String?
    }

    static let window: TimeInterval = 60
    static let interval: TimeInterval = 1

    let pasted: String
    private let before: String, after: String
    private let element: AXUIElement
    private let reader: Reader
    private let secureInput: () -> Bool
    private let now: () -> TimeInterval
    private let started: TimeInterval
    private let done: (End, [AutoLearn.Pair]) -> Void
    private var timer: Timer?
    private(set) var end: End?
    /// The field was seen as before + pasted + after once: the span is where the paste went.
    private(set) var verified = false
    /// The span as last read, once verified.
    private(set) var latest: String?

    /// nil when no element has focus to watch. `before` and `after` are the field's text around the paste, read for
    /// the paste itself. `done` gets the pairs to learn once, when the watch ends: none after a secure field or
    /// Secure Input, whatever was read before it.
    init?(pasted: String, before: String, after: String, reader: Reader, secureInput: @escaping () -> Bool,
          now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
          done: @escaping (End, [AutoLearn.Pair]) -> Void) {
        guard let element = reader.focused() else { return nil }
        self.pasted = pasted
        self.before = before
        self.after = after
        self.element = element
        self.reader = reader
        self.secureInput = secureInput
        self.now = now
        self.done = done
        started = now()
    }

    /// Polls every `interval` until the watch ends. The first poll is now.
    func start() {
        poll()
        guard end == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// One look at the field. Only the pasted element is read: when another one has focus, the watch ends first.
    func poll() {
        guard end == nil else { return }
        if now() - started >= Self.window { return stop(.timeout) }
        if secureInput() { return stop(.secure) }
        guard let el = reader.focused(), CFEqual(el, element) else { return stop(.focusLeft) }
        if reader.isSecure(el) { return stop(.secure) }
        guard let text = reader.text(el), let span = AutoLearn.span(in: text, before: before, after: after) else { return }
        if span == pasted { verified = true }
        if verified { latest = span }
    }

    /// Ends the watch; what it saw is learned unless the field turned out to be secure.
    func stop(_ why: End) {
        guard end == nil else { return }
        end = why
        timer?.invalidate()
        timer = nil
        let pairs = why == .secure ? [] : latest.map { AutoLearn.learn(pasted: pasted, edited: $0, before: before) } ?? []
        done(why, pairs)
    }
}

extension EditWatch.Reader {
    /// The focused element over Accessibility, read with FocusedText's checks. Read-only: no attribute is set, so
    /// even AXManualAccessibility stays as the dictation start left it.
    static let ax = EditWatch.Reader(focused: {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.1)  // one hung app costs 0.1 s a poll, not AX's default 6 s
        return el
    }, isSecure: { el in
        [kAXRoleAttribute, kAXSubroleAttribute].contains { attribute in
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, attribute as CFString, &v) == .success
                && v as? String == (kAXSecureTextFieldSubrole as String)
        }
    }, text: { el in
        let field = FocusedText.Field(get: { name in
            var v: CFTypeRef?
            return (AXUIElementCopyAttributeValue(el, name as CFString, &v), v)
        }, string: { range in
            var range = range
            var v: CFTypeRef?
            guard let param = AXValueCreate(.cfRange, &range),
                  AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString,
                                                             param, &v) == .success else { return nil }
            return v as? String
        })
        return FocusedText.read(field, log: { _ in })?.0  // once a second: FocusedText's log line would flood the log
    })
}

/// The app's side of F26: starts a watch after each paste that landed, writes what it learns to dictionary.txt and
/// says so next to 🤫, and undoes the last batch from the 🤫 menu. Settings' "Learn words from my edits" (on by
/// default) is read at each paste.
@MainActor
final class AutoLearner: NSObject {
    static let settingKey = "learnFromEdits"
    static func isOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: settingKey) as? Bool ?? true }

    let dictionary: URL
    private let hint: (String) -> Void
    var defaults = UserDefaults.standard
    var reader = EditWatch.Reader.ax
    var secureInput: () -> Bool = { SecureInput.blocker() != nil }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private(set) var watch: EditWatch?
    /// The last batch learned in this run, until it is undone: the 🤫 menu offers to forget it.
    private(set) var lastBatch: Vocabulary.LearnedBatch?

    init(dictionary: URL, hint: @escaping (String) -> Void) {
        self.dictionary = dictionary
        self.hint = hint
        super.init()
    }

    /// After a paste that landed: `pasted` is the text that went in, `field` the text around it read for the paste.
    func pasted(_ pasted: String, into field: FocusedText.Context) {
        watch?.stop(.nextDictation)
        watch = nil
        guard Self.isOn(defaults) else { return }
        watch = EditWatch(pasted: pasted, before: field.before, after: field.after, reader: reader,
                          secureInput: secureInput, now: now) { [weak self] _, pairs in self?.learn(pairs) }
        watch?.start()
    }

    /// At the start of the next dictation: the user is done editing.
    func dictationStarted() {
        watch?.stop(.nextDictation)
        watch = nil
    }

    func learn(_ pairs: [AutoLearn.Pair]) {
        guard !pairs.isEmpty else { return }
        do {
            guard let batch = try Vocabulary.appendLearned(pairs.map(\.entry), to: dictionary) else { return }
            lastBatch = batch
            hint(Self.learnedHint(batch.entries))
        } catch {
            NSLog("shepetal: learn: %@", error.localizedDescription)
        }
    }

    /// The 🤫 menu's undo item shows these words, and only while there are some.
    var undoWords: [String] { lastBatch?.entries.map(\.written) ?? [] }

    /// The 🤫 menu's undo item, with what needs doing at the top: hidden until a word is learned, gone once undone,
    /// never grey. Its own target, like F102's off switch, so it needs no MenuAction.
    func addMenuItem(to menu: NSMenu) {
        guard !undoWords.isEmpty else { return }
        let item = NSMenuItem(title: "Forget learned " + undoWords.map { "“\($0)”" }.joined(separator: ", "),
                              action: #selector(undoClicked(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        // Nothing else needs doing: the meetings group is first, so the item gets its own group.
        if menu.items.first?.representedObject as? MenuAction == .meeting { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(item, at: 0)
    }

    @objc private func undoClicked(_ sender: NSMenuItem) { undo() }

    func undo() {
        guard let batch = lastBatch else { return }
        lastBatch = nil
        let undone = (try? Vocabulary.undoLearned(batch, at: dictionary)) == true
        hint(undone ? "Forgot \(Self.list(batch.entries))" : "dictionary.txt changed since; remove the words in Settings > Dictionary…")
    }

    static func learnedHint(_ entries: [Vocabulary.Entry]) -> String { "Learned: " + entries.map(\.written).joined(separator: ", ") }
    private static func list(_ entries: [Vocabulary.Entry]) -> String { entries.map { "“\($0.written)”" }.joined(separator: ", ") }
}
