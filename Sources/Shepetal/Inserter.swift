import AppKit
import Carbon
import ShepetalCore

/// Inserts text with the clipboard plus a synthesized Cmd+V. The text is a promised pasteboard item,
/// so an app pulling it is the success signal; the user's clipboard comes back about 500 ms later.
@MainActor
final class Inserter: NSObject, NSPasteboardItemDataProvider {
    struct Result { let landed: Bool; let restored: Bool }

    let pasteboard: NSPasteboard
    // Written by the pasteboard callback, which AppKit may call off the main thread.
    private let lock = NSLock()
    nonisolated(unsafe) private var text = ""
    nonisolated(unsafe) private var requested: TimeInterval?
    private var requestedAt: TimeInterval? { lock.withLock { requested } }
    private static let markers = [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                                  NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]

    /// `.general` in the app; the end-to-end test passes a private pasteboard so it never touches the user's clipboard.
    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// `sendPaste` delivers the Cmd+V chord; the app posts it to the system (`postCmdV`).
    func insert(_ text: String, sendPaste: (CGEvent) -> Void) async -> Result {
        let saved = snapshot()
        lock.withLock {
            self.text = text
            requested = nil
        }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        for m in Self.markers { item.setData(Data(), forType: m) }  // clipboard managers skip it
        pasteboard.writeObjects([item])

        let posted = now
        for event in Self.cmdV() { sendPaste(event) }
        while PasteCheck.verdict(postedAt: posted, requestedAt: requestedAt, now: now) == .waiting {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let landed = PasteCheck.verdict(postedAt: posted, requestedAt: requestedAt, now: now) == .landed
        if !landed {
            // Nothing took the paste (focus moved, or the app ignores Cmd+V).
            leaveOnClipboard(text)
            return Result(landed: false, restored: false)
        }
        let wait = PasteCheck.restoreAt(postedAt: posted, requestedAt: requestedAt) - now
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        restore(saved)
        return Result(landed: landed, restored: snapshot() == saved)
    }

    /// Rule 8: text that is not pasted stays on the clipboard as plain text, so the user can press ⌘V.
    /// The user's old clipboard is not restored then.
    /// The Concealed and Transient markers stay on it: clipboard managers skip it, and ⌘V still pastes it.
    func leaveOnClipboard(_ text: String) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for m in Self.markers { item.setData(Data(), forType: m) }
        pasteboard.writeObjects([item])
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let text = lock.withLock {
            if requested == nil { requested = ProcessInfo.processInfo.systemUptime }
            return self.text
        }
        item.setString(text, forType: type)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func restore(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Key down and up for Cmd plus the key that types "v" in the current layout.
    /// Only the Command flag is set, so a held fn or other modifier does not leak into the chord.
    static func cmdV() -> [CGEvent] {
        let source = CGEventSource(stateID: .hidSystemState)
        return [true, false].compactMap { down in
            let e = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode(), keyDown: down)
            e?.flags = .maskCommand
            return e
        }
    }

    static func postCmdV(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
        if event.type == .keyDown { usleep(5_000) }
    }

    /// Reverse lookup of "v" in the active keyboard layout; 9 (ANSI V) when there is none.
    static func vKeyCode() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return 9 }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == 0x76 { return CGKeyCode(code) }
            }
            return 9
        }
    }
}

/// Text around the cursor of the focused field, and the selection the paste replaces, through
/// Accessibility (`AXValue` and `AXSelectedTextRange`). Empty when unreadable.
enum FocusedText {
    static func context() -> (before: String, after: String) {
        read().map { split($0, $1) } ?? ("", "")
    }

    static func selected() -> String {
        read().map { selection($0, $1) } ?? ""
    }

    /// The focused app's pid and its focused window, to tell at paste time whether focus moved (rule 8).
    /// Without Accessibility only the frontmost app is known, and the window is nil.
    static func window() -> (app: Int32, window: AXUIElement?)? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString,
                                            &app) == .success, let app else {
            return PasteGate.focus(axPid: nil, frontmostPid: frontmost, window: nil as AXUIElement?)
        }
        let element = app as! AXUIElement
        // This runs on the main thread at fn-down: a hung app must not stall fn handling for AX's default 6 s.
        AXUIElementSetMessagingTimeout(element, 0.1)
        var pid: pid_t = 0
        let axPid: Int32? = AXUIElementGetPid(element, &pid) == .success ? pid : nil
        var window: CFTypeRef?
        let ok = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success
        return PasteGate.focus(axPid: axPid, frontmostPid: frontmost, window: ok ? (window as! AXUIElement) : nil)
    }

    private static let textTimeout: Float = 0.25  // a whole document's AXValue is the slowest read

    /// Runs on the main thread just before a paste. Each element gets a short timeout: a busy app must not
    /// freeze Shepetal for AX's default (1.5 s per call measured on macOS 15). A slow field reads as unknown.
    /// An unreadable field logs which attribute failed and the AX error code, never the text.
    private static func read() -> (String, NSRange)? {
        var app: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app)
        guard err == .success, let app else { return unreadable(kAXFocusedApplicationAttribute, err) }
        let appEl = app as! AXUIElement
        AXUIElementSetMessagingTimeout(appEl, textTimeout)
        var focused: CFTypeRef?
        err = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return unreadable(kAXFocusedUIElementAttribute, err) }
        let el = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(el, textTimeout)
        var value: CFTypeRef?
        err = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
        guard err == .success, let string = value as? String else { return unreadable(kAXValueAttribute, err) }
        var rangeRef: CFTypeRef?
        var range = CFRange()
        err = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard err == .success, let rangeRef, AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else {
            return unreadable(kAXSelectedTextRangeAttribute, err)
        }
        return (string, NSRange(location: range.location, length: range.length))
    }

    private static func unreadable(_ attribute: String, _ err: AXError) -> (String, NSRange)? {
        NSLog("shepetal: context: %@ unreadable (AX %d), text goes in as dictated", attribute, err.rawValue)
        return nil
    }

    /// The selected text, or "" when the range is not inside the text.
    static func selection(_ s: String, _ r: NSRange) -> String {
        valid(r, in: s) ? (s as NSString).substring(with: r) : ""
    }

    /// The text before and after the selection. A range outside the text (stale, or counted in other units)
    /// gives no context: guessing the cursor from it would change the dictation's case and punctuation on a guess.
    static func split(_ s: String, _ selection: NSRange) -> (before: String, after: String) {
        guard valid(selection, in: s) else { return ("", "") }
        let ns = s as NSString
        return (ns.substring(to: selection.location), ns.substring(from: NSMaxRange(selection)))
    }

    private static func valid(_ r: NSRange, in s: String) -> Bool {
        let length = (s as NSString).length
        return r.location >= 0 && r.length >= 0 && r.location <= length && r.length <= length - r.location
    }
}
