import AppKit
import ShepetalCore

/// Watches keys, modifiers (fn is keycode 63, Globe 179) and mouse buttons 3 to 10 with a CGEventTap and
/// feeds them to the `KeyRouter`, which decides everything. With Accessibility the tap is active and drops
/// what the router says (Esc during a dictation, the Space of fn+Space); without it the tap only listens.
/// Re-enables the tap when macOS turns it off, and releases every key whose key-up was lost meanwhile.
final class FnTap {
    var router = KeyRouter()
    var onInput: ((KeyInput) -> Void)?
    /// A dictation or a transcription is running (Esc is ours then). Read from memory: the callback must be fast.
    var isActive: () -> Bool = { false }
    /// Whether a held key is physically up; a seam for tests.
    var isUp: (Int) -> Bool = FnTap.systemIsUp
    private(set) var canSwallow = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?

    var isRunning: Bool { tap != nil }

    /// Needs Input Monitoring. Creating a tap without it would prompt, so callers check first.
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let active = AXIsProcessTrusted()  // an active tap needs Accessibility
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: active ? .defaultTap : .listenOnly,
                                          eventsOfInterest: mask, callback: fnTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        canSwallow = active
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            self.reenable()
        }
        return true
    }

    /// Removes the tap, so the next `start` can create it again (listen-only to active once Accessibility is on).
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        watchdog?.invalidate()
        self.tap = nil
    }

    /// Returns true when the event must not reach the front app.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable()
            return false
        }
        // Our own Cmd+V (paste) is not a key the user pressed.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return false }
        let code: Int
        let down: Bool
        switch type {
        case .flagsChanged:
            code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let d = Key.modifierDown(code, flags: event.flags.rawValue) else { return false }
            down = d
        case .keyDown, .keyUp:
            code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            down = type == .keyDown
        case .otherMouseDown, .otherMouseUp:
            code = Key.mouse(Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1)
            down = type == .otherMouseDown
        default:
            return false
        }
        let flags = event.flags.rawValue
        let stale = router.releaseStale { $0 != code && Key.flagUp($0, flags: flags) }
        let (inputs, swallow) = router.key(code, down: down, active: isActive(), canSwallow: canSwallow)
        (stale + inputs).forEach { onInput?($0) }
        return swallow
    }

    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        router.releaseStale(isUp: isUp).forEach { onInput?($0) }
    }

    static func systemIsUp(_ code: Int) -> Bool {
        if Key.normal(code) == Key.fn { return !CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) }
        if let n = Key.mouseButton(code), let button = CGMouseButton(rawValue: UInt32(n - 1)) {
            return !CGEventSource.buttonState(.hidSystemState, button: button)
        }
        return !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
    }
}

private func fnTapCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<FnTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
