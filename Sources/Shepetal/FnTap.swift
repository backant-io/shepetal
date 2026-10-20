import AppKit
import ShepetalCore

/// Listens for fn (keycode 63, Globe 179) with a listen-only CGEventTap. Re-enables the tap when
/// macOS turns it off, and releases fn if its key-up was lost while the tap was off.
final class FnTap {
    var onChange: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var isDown = false
    private var watchdog: Timer?

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

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return reenable() }
        let keyDown: Bool? = type == .keyDown ? true : type == .keyUp ? false : nil
        guard let down = FnKey.transition(keycode: event.getIntegerValueField(.keyboardEventKeycode),
                                          secondaryFn: event.flags.contains(.maskSecondaryFn), isKeyDown: keyDown),
              down != isDown else { return }
        isDown = down
        onChange?(down)
    }

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        if isDown && !CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) {
            isDown = false
            onChange?(false)
        }
    }
}

private func fnTapCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<FnTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
    return Unmanaged.passUnretained(event)
}
