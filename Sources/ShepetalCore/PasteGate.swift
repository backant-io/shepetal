/// Product rule 8: the text is pasted only into the window that was focused when the dictation started,
/// and focus is never moved back. Otherwise the text is left on the clipboard and the hint says to press ⌘V.
public enum PasteGate {
    public static let pressCmdV = "The text is on the clipboard: press ⌘V to paste it."
    public static let focusMoved = "The window changed while you spoke. " + pressCmdV
    public static let notLanded = "Paste did not land. " + pressCmdV

    public static func secureInput(_ app: String) -> String { "Secure input is on in \(app). " + pressCmdV }

    /// Whether the window focused now is the one focused when the dictation started. `app` is a pid, `window`
    /// the focused window (nil when it could not be read). Nil when focus cannot be compared: the paste goes
    /// ahead and the paste check is the backstop.
    public static func focusKept<W: Equatable>(start: (app: Int32, window: W?)?, now: (app: Int32, window: W?)?) -> Bool? {
        guard let start, let now else { return nil }
        guard start.app == now.app else { return false }
        guard let a = start.window, let b = now.window else { return nil }
        return a == b
    }

    /// The focus record `focusKept` compares, from what could be read. `axPid` is the AX focused app's pid (nil when
    /// unreadable), `frontmostPid` the frontmost app's. A window that could not be read stays nil but the app is
    /// still recorded, so a move to another app is caught even then.
    public static func focus<W>(axPid: Int32?, frontmostPid: Int32?, window: W?) -> (app: Int32, window: W?)? {
        guard let pid = axPid ?? frontmostPid else { return nil }
        return (pid, axPid == nil ? nil : window)
    }

    /// The message when the text goes to the clipboard instead of being pasted, or nil to paste.
    public static func blocked(focusKept: Bool?, secureInputApp: String?) -> String? {
        if focusKept == false { return focusMoved }
        return secureInputApp.map(secureInput)
    }
}
