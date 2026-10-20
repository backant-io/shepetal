import Foundation

/// What the shell does after an fn event or a timer tick.
public enum GestureAction: Equatable {
    case start          // open the mic: recording begins on the first press
    case lockHandsFree  // second tap inside the window: keep recording without holding fn
    case stop           // transcribe and insert
    case tooShort       // nothing is transcribed or inserted; the audio is kept and the hint shows
    case cancel         // fn was a modifier (fn+Delete, fn+arrow): nothing is transcribed, the audio is kept, no hint
}

/// fn gestures: hold to talk, double-tap for hands-free, a tap ends hands-free,
/// a press shorter than the hold threshold with no second tap is dropped.
/// Times are seconds on any monotonic clock. The shell calls `tick` at `deadline`.
public struct FnGesture: Equatable {
    public enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        case awaitingSecondTap(deadline: TimeInterval)
        case handsFree
    }

    public var holdThreshold: TimeInterval = 0.5
    public var doubleTapWindow: TimeInterval = 0.5
    public var chordWindow: TimeInterval = 1.0
    public private(set) var state: State = .idle

    public init() {}

    /// When the shell must call `tick` to settle a short press.
    public var deadline: TimeInterval? {
        if case .awaitingSecondTap(let d) = state { return d }
        return nil
    }

    public mutating func fnDown(at t: TimeInterval) -> [GestureAction] {
        switch state {
        case .idle:
            state = .holding(since: t)
            return [.start]
        case .awaitingSecondTap(let d) where t <= d:
            state = .handsFree
            return [.lockHandsFree]
        case .awaitingSecondTap:
            // The tick was late: settle the old short press, then this press starts a new one.
            state = .holding(since: t)
            return [.tooShort, .start]
        case .handsFree:
            state = .idle
            return [.stop]
        case .holding:
            return []  // key repeat or a duplicate event
        }
    }

    public mutating func fnUp(at t: TimeInterval) -> [GestureAction] {
        guard case .holding(let since) = state else { return [] }
        if t - since < holdThreshold {
            state = .awaitingSecondTap(deadline: t + doubleTapWindow)
            return []
        }
        state = .idle
        return [.stop]
    }

    /// A key other than fn went down. In the first `chordWindow` of a hold that is a shortcut with fn,
    /// not dictation (docs/re/dictation-input.md 1, "Chord collision cancels").
    public mutating func otherKeyDown(at t: TimeInterval) -> [GestureAction] {
        guard case .holding(let since) = state, t - since < chordWindow else { return [] }
        state = .idle
        return [.cancel]
    }

    public mutating func tick(at t: TimeInterval) -> [GestureAction] {
        guard case .awaitingSecondTap(let d) = state, t >= d else { return [] }
        state = .idle
        return [.tooShort]
    }

    /// Ends whatever is running without a result (Esc, errors).
    public mutating func reset() { state = .idle }
}

/// The short-press hint shown next to the indicator. Our own wording.
public enum Hint {
    public static let shortPress = "Hold fn to talk · double-tap for hands-free"
    public static let seconds: TimeInterval = 2
}

/// Which events are fn. fn is keycode 63 on flagsChanged; newer Apple keyboards send the Globe key as 179.
public enum FnKey {
    public static let keycode: Int64 = 63
    public static let globe: Int64 = 179

    /// `isKeyDown` is nil for flagsChanged, true/false for keyDown/keyUp.
    /// Returns true when fn went down, false when it went up, nil when the event is not fn.
    public static func transition(keycode: Int64, secondaryFn: Bool, isKeyDown: Bool?) -> Bool? {
        guard keycode == Self.keycode || keycode == globe else { return nil }
        return isKeyDown ?? secondaryFn
    }
}
