import AppKit
import ShepetalCore

/// Watches keys, modifiers (fn is keycode 63) and mouse buttons 3 to 10 with a CGEventTap and feeds them to
/// the `KeyRouter`, which decides everything. The Globe key's extra keycode 179 key events are ignored: read as
/// fn, the pair after a release made one tap a double-tap (Wispr drops them too, "doubleFn"). With Accessibility
/// the tap is active and drops what the router says (Esc during a dictation, the Space of fn+Space); without it,
/// or when an active tap cannot be made, the tap only listens.
/// An active tap holds every key the user types until the callback returns, so the tap runs on its own thread:
/// a busy main thread (opening the mic, Accessibility calls into a slow app) never delays typing.
/// Re-enables the tap when macOS turns it off, and releases every key whose key-up was lost meanwhile.
final class FnTap {
    /// On the tap's thread. `t` is the uptime when the key moved (`FnClock`).
    var onInput: ((KeyInput, TimeInterval) -> Void)?
    /// Whether a held key is physically up; a seam for tests.
    var isUp: (Int) -> Bool = FnTap.systemIsUp
    private(set) var canSwallow = false
    private let lock = NSLock()
    private var _router = KeyRouter()
    private var _active = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var watchdog: Timer?

    var isRunning: Bool { tap != nil }

    /// A dictation, or a transcription before its paste, is running: Esc is ours then. The main thread sets it;
    /// the callback reads it from memory, because it must be fast.
    var isActive: Bool {
        get { lock.withLock { _active } }
        set { lock.withLock { _active = newValue } }
    }

    var router: KeyRouter { lock.withLock { _router } }

    /// Changes the router (shortcuts, recording) under the lock the tap's thread uses.
    @discardableResult
    func updateRouter<T>(_ change: (inout KeyRouter) -> T) -> T { lock.withLock { change(&_router) } }

    /// Needs Input Monitoring. Creating a tap without it would prompt, so callers check first.
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        func make(_ options: CGEventTapOptions) -> CFMachPort? {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                              eventsOfInterest: mask, callback: fnTapCallback, userInfo: me)
        }
        // An active tap needs Accessibility; listening is the fallback.
        let active = AXIsProcessTrusted() ? make(.defaultTap) : nil
        guard let tap = active ?? make(.listenOnly) else { return false }
        self.tap = tap
        canSwallow = active != nil
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()  // returns once `stop` removes the source and stops the loop
        }
        thread.name = "io.backant.shepetal.keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            self.reenable()
        }
        return true
    }

    /// Removes the tap, so the next `start` can create it again (listen-only to active once Accessibility is on,
    /// and back when it is revoked).
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        CFMachPortInvalidate(tap)
        watchdog?.invalidate()
        self.tap = nil
        runLoop = nil
    }

    /// Returns true when the event must not reach the front app.
    @discardableResult
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
            if code == Key.globe { return false }  // neither fn nor another key (see above)
            down = type == .keyDown
        case .otherMouseDown, .otherMouseUp:
            code = Key.mouse(Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1)
            down = type == .otherMouseDown
        default:
            return false
        }
        let t = FnClock.seconds(timestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime)
        let flags = event.flags.rawValue
        let isUp = isUp
        let (inputs, swallow) = lock.withLock {
            // Key-ups the tap never saw (secure input hides them): a modifier whose flag is gone, and on a press,
            // any other held key that is up now. Left held, they would keep every chord from matching.
            let stale = _router.releaseStale {
                $0 != code && (Key.flagUp($0, flags: flags) || (down && !Key.isModifier($0) && isUp($0)))
            }
            let (inputs, swallow) = _router.key(code, down: down, active: _active, canSwallow: canSwallow)
            return (stale + inputs, swallow)
        }
        inputs.forEach { onInput?($0, t) }
        return swallow
    }

    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        let isUp = isUp
        let inputs = lock.withLock { _router.releaseStale(isUp: isUp) }
        inputs.forEach { onInput?($0, ProcessInfo.processInfo.systemUptime) }
    }

    static func systemIsUp(_ code: Int) -> Bool {
        if code == Key.fn { return !CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) }
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
