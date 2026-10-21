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

/// Text around the cursor of the focused field, and the selection the paste replaces, through Accessibility
/// (docs/re/insertion-context.md 2.4.2). Empty when unreadable, or when the range and the text disagree: the
/// text then goes in as dictated, since a guessed cursor would change its case and punctuation on a guess.
enum FocusedText {
    typealias Context = (before: String, after: String, selected: String)

    /// One element's AX attributes, so tests can stand in for an app's answers without an AX call.
    struct Field {
        var get: (_ attribute: String) -> (AXError, CFTypeRef?)
        var string: (_ range: CFRange) -> String?  // AXStringForRange
    }

    /// Read once per dictation, after transcription.
    static func context() -> Context {
        focused().map { context($0) } ?? ("", "", "")
    }

    static func context(_ field: Field, log: (String) -> Void = { NSLog("shepetal: context: %@", $0) }) -> Context {
        guard let (s, r) = read(field, log: log) else { return ("", "", "") }
        let (before, after) = split(s, r)
        return (before, after, selection(s, r))
    }

    /// The focused app's pid and its focused window, to tell at paste time whether focus moved (rule 8).
    /// Without Accessibility only the frontmost app is known, and the window is nil.
    static func window() -> (app: Int32, window: AXUIElement?)? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let app = element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute).0 else {
            return PasteGate.focus(axPid: nil, frontmostPid: frontmost, window: nil as AXUIElement?)
        }
        // This runs on the main thread at fn-down: a hung app must not stall fn handling for AX's default 6 s.
        AXUIElementSetMessagingTimeout(app, 0.1)
        askForTree { AXUIElementSetAttributeValue(app, $0 as CFString, $1) }
        var pid: pid_t = 0
        let axPid: Int32? = AXUIElementGetPid(app, &pid) == .success ? pid : nil
        return PasteGate.focus(axPid: axPid, frontmostPid: frontmost, window: element(app, kAXFocusedWindowAttribute).0)
    }

    /// Electron apps (VS Code, Slack, Obsidian) build the AX tree of their text fields only when asked (2.4.9).
    /// Asked at dictation start, the tree is there when the text is ready; before, the read found no text and
    /// every dictation went in as dictated. Apps without the attribute ignore it.
    /// ponytail: AXEnhancedUserInterface (VoiceOver's switch) is not set: with it, window managers' moves and
    /// resizes of the app turn slow and animated. Set it for browsers if Chrome fields still read empty.
    static func askForTree(_ set: (_ attribute: String, _ value: CFTypeRef) -> AXError) {
        _ = set("AXManualAccessibility", kCFBooleanTrue)
    }

    /// An attribute that holds an element. Another type is nil, not a crashing cast.
    private static func element(_ of: AXUIElement, _ attribute: String) -> (AXUIElement?, AXError) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(of, attribute as CFString, &value)
        guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, err) }
        return ((value as! AXUIElement), err)
    }

    private static func focused() -> Field? {
        let (el, err) = element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        guard let el else {
            NSLog("shepetal: context: no focused element (AX %d), text goes in as dictated", err.rawValue)
            return nil
        }
        return Field(get: { name in
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
    }

    /// The field's text and selection. Every read logs one line: the role, the length and the selection, or what
    /// failed with its AX code. Never the text. An app that does not answer costs one AX timeout, not one per
    /// attribute: the read stops at the first call that times out.
    static func read(_ field: Field, log: (String) -> Void) -> (String, NSRange)? {
        var hung = false
        let f = Field(get: { name in
            if hung { return (.cannotComplete, nil) }
            let answer = field.get(name)
            hung = answer.0 == .cannotComplete
            return answer
        }, string: { hung ? nil : field.string($0) })
        let (roleErr, roleRef) = f.get(kAXRoleAttribute)
        let role = roleRef as? String ?? "no role"
        func unreadable(_ why: String) -> (String, NSRange)? {
            log("\(role): \(why), text goes in as dictated")
            return nil
        }
        if hung { return unreadable("no answer (AX \(roleErr.rawValue))") }  // not shown: logged
        let (rangeErr, rangeRef) = f.get(kAXSelectedTextRangeAttribute)
        var cf = CFRange()
        guard let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID(), AXValueGetValue(rangeRef as! AXValue, .cfRange, &cf) else {
            return unreadable("\(kAXSelectedTextRangeAttribute) unreadable (AX \(rangeErr.rawValue))")  // not shown: logged
        }
        // The text is AXValue, unless AXNumberOfCharacters, which counts in the range's units, disagrees with it:
        // then it is AXStringForRange over all of them (2.4.2).
        let (valueErr, valueRef) = f.get(kAXValueAttribute)
        var text = valueRef as? String
        if let n = f.get(kAXNumberOfCharactersAttribute).1 as? Int, n >= 0, n != text.map({ ($0 as NSString).length }) {
            text = f.string(CFRange(location: 0, length: n))
            if text == nil { return unreadable("\(kAXValueAttribute) is not its \(n) characters") }
        }
        guard let text else { return unreadable("\(kAXValueAttribute) unreadable (AX \(valueErr.rawValue))") }  // not shown: logged
        let ns = text as NSString
        var range = NSRange(location: cf.location, length: cf.length)
        guard valid(range, in: text) else { return unreadable("selection \(cf.location)+\(cf.length) outside its \(ns.length) characters") }

        // A range inside the text can still be wrong: stale, or counted on another node. The selected text, when
        // the app gives it, says where the selection is; a selection found once in the text is used (as Flow does).
        if let sel = f.get(kAXSelectedTextAttribute).1 as? String, sel != ns.substring(with: range) {
            let at = ns.range(of: sel)
            guard !sel.isEmpty, at.location != NSNotFound, ns.range(of: sel, options: .backwards) == at else {
                return unreadable("\(kAXSelectedTextAttribute) does not match \(kAXSelectedTextRangeAttribute)")
            }
            range = at
        }
        // And the app's own text around the cursor must be the text read.
        let lo = max(0, range.location - 20), around = NSRange(location: lo, length: min(ns.length, NSMaxRange(range) + 20) - lo)
        if let s = f.string(CFRange(location: around.location, length: around.length)), s != ns.substring(with: around) {
            return unreadable("AXStringForRange does not match \(kAXValueAttribute) at the cursor")
        }
        log("\(role), \(ns.length) characters, selection \(range.location)+\(range.length)")
        return (text, range)
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
