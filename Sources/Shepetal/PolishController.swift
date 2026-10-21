import AppKit
import ShepetalCore

/// F45 Polish: the selected text, rewritten on this Mac by the cleanup model with the active saved prompt. The window
/// focused at the hotkey is remembered; the rewrite is pasted over the selection only when that window is still
/// focused and the selection is unchanged (rule 8). Otherwise it is left on the clipboard as plain text with the ⌘V
/// hint. Focus is never moved back. A model error, or an empty or runaway answer, leaves the selection and the
/// clipboard as they were. Each rewrite is kept in history.sqlite's polish table with its input and output (F46).
@MainActor
final class PolishController: NSObject {
    /// What a Polish needs from the Mac. `live` reads the real focus and selection; tests pass fakes.
    struct Mac {
        /// Called at the hotkey: remembers the focused window, and returns whether that window is still the focused
        /// one each time it is called (nil: unknown, the paste check is the backstop).
        var rememberFocus: @MainActor () -> () -> Bool?
        /// The focused field's selected text: "" when nothing is selected or the field cannot be read.
        var selection: @MainActor () -> String
        var secureInput: @MainActor () -> String?
        var app: @MainActor () -> Task<AppContext, Never>
        var sendPaste: @MainActor (CGEvent) -> Void

        static let live = Mac(rememberFocus: {
            let start = FocusedText.window()  // also asks Electron apps for their text fields' AX tree
            return { PasteGate.focusKept(start: start, now: FocusedText.window()) }
        }, selection: { FocusedText.context().selected }, secureInput: SecureInput.blocker,
           app: AppContext.capture, sendPaste: Inserter.postCmdV)
    }

    /// The model, or why there is none (for the hint).
    enum Model {
        case ready(TextRewriter)
        case notDownloaded, downloading, loading, couldNotLoad
        case unavailable  // no cleanup model for this Mac (Intel)
    }

    let inserter: Inserter
    let history: History
    let model: () -> Model
    var mac: Mac
    let defaults: UserDefaults
    /// The 🤫 ring, and a hint next to 🤫 for some seconds. The app sets both.
    var indicator: (Indicator.Mode) -> Void = { _ in }
    var show: (String, TimeInterval) -> Void = { _, _ in }
    /// An Electron app builds its text fields' AX tree only when asked (at the hotkey): an empty selection is read once more after this.
    var retryDelay: Duration = .milliseconds(150)
    private(set) var running: Task<Void, Never>?

    init(inserter: Inserter, history: History, model: @escaping () -> Model, mac: Mac = .live, defaults: UserDefaults = .standard) {
        self.inserter = inserter
        self.history = history
        self.model = model
        self.mac = mac
        self.defaults = defaults
    }

    /// The model state of `pipeline`'s cleanup model.
    static func model(_ pipeline: Pipeline) -> Model {
        if let rewriter = pipeline.cleanup as? TextRewriter { return .ready(rewriter) }
        if pipeline.cleanupPath == nil { return .unavailable }
        if pipeline.downloadingCleanup { return .downloading }
        if pipeline.cleanupToDownload != nil { return .notDownloaded }
        return pipeline.cleanupStatus == "Loading…" ? .loading : .couldNotLoad
    }

    /// The hotkey. One Polish at a time, and none while a dictation runs or pastes.
    /// ponytail: a dictation may still start while the model runs; if its paste falls in the half second of this
    /// one's, they share the one Inserter and one of them ends on the clipboard. Block fn during the paste if seen.
    func start(dictating: Bool) {
        if running != nil { return show(Polish.running, Hint.seconds) }
        if dictating { return show(Polish.busy, Hint.seconds) }
        running = Task {
            await run()
            running = nil
        }
    }

    /// One Polish. Returns the message shown, nil when the rewrite was pasted over the selection.
    @discardableResult
    func run() async -> String? {
        let focusKept = mac.rememberFocus()  // first: the window the user is in now
        let app = mac.app()
        var input = mac.selection()
        if input.isEmpty {
            try? await Task.sleep(for: retryDelay)
            input = mac.selection()
        }
        guard input.contains(where: { !$0.isWhitespace }) else { return hint(Polish.selectFirst) }
        guard Polish.words(input) <= Polish.maxWords else { return hint(Polish.tooLong) }
        let rewriter: TextRewriter
        switch model() {
        case .ready(let r): rewriter = r
        case .notDownloaded: return hint(Polish.needsModel)
        case .downloading: return hint(Polish.downloading)
        case .loading: return hint(Polish.loading)
        case .couldNotLoad: return fail(Polish.failed)
        case .unavailable: return hint(Polish.notOnThisMac)
        }
        let prompt = PolishPrompts.active(defaults)
        indicator(.processing)
        let answer = await Task.detached { try? rewriter.rewrite(instruction: prompt.instruction, text: input) }.value
        guard let answer, let output = Polish.accept(answer, for: input) else { return fail(Polish.failed) }
        guard output != input else { return hint(Polish.unchanged) }

        let context = await app.value
        var entry = PolishEntry(outcome: .pasteFailed, app: context.name, bundleId: context.bundleId, promptName: prompt.name,
                                instruction: prompt.instruction, input: input, output: output)
        defer { try? history.addPolish(entry) }
        // Rule 8, before the selection is read again (another window's field is not read) and after it.
        if let message = blocked(focusKept) ?? (mac.selection() == input ? nil : Polish.selectionChanged) ?? blocked(focusKept) {
            inserter.leaveOnClipboard(output)
            return fail(message)
        }
        let paste = await inserter.insert(output, mode: PasteMode.current(for: context.bundleId), sendPaste: mac.sendPaste,
                                          stillFocused: { [self] in blocked(focusKept) == nil })
        guard paste.landed else { return fail(PasteGate.notLanded) }  // the inserter left it on the clipboard
        entry.outcome = .inserted
        indicator(.idle)
        return nil
    }

    /// Why the rewrite must not be pasted now, or nil.
    private func blocked(_ focusKept: () -> Bool?) -> String? {
        if focusKept() == false { return Polish.focusMoved }
        return mac.secureInput().map(PasteGate.secureInput)
    }

    private func hint(_ message: String) -> String {
        indicator(.idle)
        show(message, Hint.seconds)
        return message
    }

    private func fail(_ message: String) -> String {
        indicator(.error)
        show(message, 4)
        return message
    }

    // MARK: 🤫 menu

    /// "Polish prompt (⌃ ⌘ P)": the saved prompts, the active one checked; a click makes a prompt the active one.
    /// nil on a Mac without the cleanup model.
    func menuItem(chord: Set<Int>) -> NSMenuItem? {
        if case .unavailable = model() { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false  // every item is enabled (#207)
        let active = PolishPrompts.active(defaults).name
        for p in PolishPrompts.load(defaults) {
            let i = NSMenuItem(title: p.name, action: #selector(choose(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.name
            i.state = p.name == active ? .on : .off
            menu.addItem(i)
        }
        let item = NSMenuItem(title: chord.isEmpty ? "Polish prompt" : "Polish prompt (\(Key.label(chord)))", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        PolishPrompts.setActive(name, defaults)
    }
}
