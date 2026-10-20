import AppKit
import Carbon
import ShepetalCore

/// Inserts text with the clipboard plus a synthesized Cmd+V. The text is a promised pasteboard item,
/// so an app pulling it is the success signal; the user's clipboard comes back about 500 ms later.
@MainActor
final class Inserter: NSObject, NSPasteboardItemDataProvider {
    struct Result { let landed: Bool; let restored: Bool }

    private let pasteboard: NSPasteboard
    // Written by the pasteboard callback, which AppKit may call off the main thread.
    private let lock = NSLock()
    nonisolated(unsafe) private var text = ""
    nonisolated(unsafe) private var requested: TimeInterval?
    private var requestedAt: TimeInterval? { lock.withLock { requested } }
    private static let markers = [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                                  NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]

    /// `.general` in the app; the end-to-end test passes a private pasteboard so it never touches the user's clipboard.
    init(pasteboard: NSPasteboard = .general) {
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
            // Nothing took the paste (focus moved, or the app ignores Cmd+V): leave the text on the
            // clipboard as plain text so the user can paste it themselves.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return Result(landed: false, restored: false)
        }
        let wait = PasteCheck.restoreAt(postedAt: posted, requestedAt: requestedAt) - now
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        restore(saved)
        return Result(landed: landed, restored: snapshot() == saved)
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

/// Text around the cursor of the focused field, through Accessibility. Empty when unreadable.
enum FocusedText {
    static func context() -> (before: String, after: String) {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return ("", "") }
        let el = element as! AXUIElement
        var value: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String,
              AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return ("", "") }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return ("", "") }
        return split(string, NSRange(location: range.location, length: range.length))
    }

    static func split(_ s: String, _ selection: NSRange) -> (before: String, after: String) {
        let ns = s as NSString
        let start = min(max(selection.location, 0), ns.length)
        let end = min(start + max(selection.length, 0), ns.length)
        return (ns.substring(to: start), ns.substring(from: end))
    }
}
