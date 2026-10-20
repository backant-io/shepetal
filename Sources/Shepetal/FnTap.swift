import AppKit
import ShepetalCore

/// Listens for fn (keycode 63, Globe 179) with a listen-only CGEventTap. Re-enables the tap when
/// macOS turns it off, and releases fn if its key-up was lost while the tap was off.
/// `onOtherKey` reports any other key pressed while fn is held (fn+Delete, fn+arrows).
final class FnTap {
    var onChange: ((Bool) -> Void)?
    var onOtherKey: (() -> Void)?
    private var tap: CFMachPort?
    private var isDown = false
    private var watchdog: Timer?
    private let fnHeld: () -> Bool

    init(fnHeld: @escaping () -> Bool = { CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) }) {
        self.fnHeld = fnHeld
    }

    var isRunning: Bool { tap != nil }

    /// Needs Input Monitoring. Creating a tap without it would prompt, so callers check first.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: fnTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            self.reenable()
        }
        return true
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return reenable() }
        let keyDown: Bool? = type == .keyDown ? true : type == .keyUp ? false : nil
        guard let down = FnKey.transition(keycode: event.getIntegerValueField(.keyboardEventKeycode),
                                          secondaryFn: event.flags.contains(.maskSecondaryFn), isKeyDown: keyDown) else {
            if keyDown == true, isDown { onOtherKey?() }
            return
        }
        guard down != isDown else { return }
        isDown = down
        onChange?(down)
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        if isDown && !fnHeld() {
            isDown = false
            onChange?(false)
        }
    }
}

private func fnTapCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<FnTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
    return Unmanaged.passUnretained(event)
}
