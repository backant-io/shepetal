import Foundation

/// What the shell does after an fn event or a timer tick.
public enum GestureAction: Equatable {
    case start          // open the mic: recording begins on the first press
    case lockHandsFree  // second tap inside the window, fn+Space, or the toggle: keep recording without holding fn
    case stop           // transcribe and insert
    case tooShort       // nothing is transcribed or inserted; the audio is kept and the hint shows
    case cancel         // fn was a modifier (fn+Delete, fn+arrow), Esc, or a quick second toggle: nothing is
                        // transcribed, the audio is kept, no hint
    case warnDuration   // one minute before the length cap; the shell shows a warning
}

/// fn gestures: hold to talk, double-tap for hands-free, a tap ends hands-free,
/// a press shorter than the hold threshold with no second tap is dropped.
/// Times are seconds on any monotonic clock. The shell calls `tick` at `deadline`.
public struct FnGesture: Equatable {
    public enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        case awaitingSecondTap(since: TimeInterval, deadline: TimeInterval)
        case handsFree(since: TimeInterval)
    }

    public var holdThreshold: TimeInterval = 0.5
    /// From the first tap's release to the second press ("0.5 s between fns"). There is no minimum tap length.
    public var doubleTapWindow: TimeInterval = 0.5
    public var chordWindow: TimeInterval = 1.0
    /// Max dictation length (docs/re/dictation-input.md 2.3); the shell reads `maxDictationMinutes`.
    public var maxDuration: TimeInterval = 20 * 60
    public var warningLead: TimeInterval = 60
    public private(set) var state: State = .idle
    private var warned = false
    private var endingPress = false  // the fn press that ended hands-free is still down

    public init() {}

    /// When the shell must call `tick`: the short-press settle, else the length warning, else the cap.
    public var deadline: TimeInterval? {
        switch state {
        case .idle: return nil
        case .awaitingSecondTap(_, let d): return d
        case .holding(let since), .handsFree(let since): return since + maxDuration - (warned ? 0 : warningLead)
        }
    }

    public mutating func fnDown(at t: TimeInterval) -> [GestureAction] {
        switch state {
        case .idle:
            begin(.holding(since: t))
            return [.start]
        case .awaitingSecondTap(let since, let d) where t <= d:
            state = .handsFree(since: since)
            return [.lockHandsFree]
        case .awaitingSecondTap:
            // The tick was late: settle the old short press, then this press starts a new one.
            begin(.holding(since: t))
            return [.tooShort, .start]
        case .handsFree:
            // The ending tap transcribes on its press (Pavel, M-FN-2). That fn may start fn+Space (the toggle):
            // its Space must not start a new session, so a toggle waits until this fn is up.
            end()
            endingPress = true
            return [.stop]
        case .holding:
            return []  // key repeat or a duplicate event
        }
    }

    public mutating func fnUp(at t: TimeInterval) -> [GestureAction] {
        endingPress = false
        switch state {
        case .holding(let since) where t - since < holdThreshold:
            state = .awaitingSecondTap(since: since, deadline: t + doubleTapWindow)
            return []
        case .holding:
            end()
            return [.stop]
        default:
            return []
        }
    }

    /// A key other than fn went down. In the first `chordWindow` of a hold that is a shortcut with fn,
    /// not dictation (docs/re/dictation-input.md 1, "Chord collision cancels").
    public mutating func otherKeyDown(at t: TimeInterval) -> [GestureAction] {
        guard case .holding(let since) = state, t - since < chordWindow else { return [] }
        end()
        return [.cancel]
    }

    /// The hands-free shortcut (fn+Space): from idle it starts locked; during a hold it locks that session
    /// (chord promotion); while locked it stops, or cancels when pressed within `doubleTapWindow` of the start.
    public mutating func toggle(at t: TimeInterval) -> [GestureAction] {
        switch state {
        case .idle where endingPress:
            return []  // the Space of the fn+Space whose fn already ended hands-free
        case .idle:
            begin(.handsFree(since: t))
            return [.start, .lockHandsFree]
        case .holding(let since), .awaitingSecondTap(let since, _):
            state = .handsFree(since: since)
            return [.lockHandsFree]
        case .handsFree(let since):
            end()
            return t - since < doubleTapWindow ? [.cancel] : [.stop]
        }
    }

    /// Esc: whatever is recording ends without a result. Idle stays idle.
    public mutating func dismiss() -> [GestureAction] {
        guard state != .idle else { return [] }
        end()
        return [.cancel]
    }

    public mutating func tick(at t: TimeInterval) -> [GestureAction] {
        switch state {
        case .idle: return []
        case .awaitingSecondTap(_, let d):
            guard t >= d else { return [] }
            end()
            return [.tooShort]
        case .holding(let since), .handsFree(let since):
            if t >= since + maxDuration {
                end()
                return [.stop]  // forced stop: transcribed and inserted like a release
            }
            guard !warned, t >= since + maxDuration - warningLead else { return [] }
            warned = true
            return [.warnDuration]
        }
    }

    /// One input from the key router.
    public mutating func handle(_ input: KeyInput, at t: TimeInterval) -> [GestureAction] {
        switch input {
        case .pttDown: fnDown(at: t)
        case .pttUp: fnUp(at: t)
        case .toggle: toggle(at: t)
        case .dismiss: dismiss()
        case .otherKey: otherKeyDown(at: t)
        case .pasteLast, .copyLast, .openNotes, .recorded: []
        case .polish: []  // F45: not a dictation
        }
    }

    /// Ends whatever is running without a result (errors).
    public mutating func reset() { end() }

    private mutating func begin(_ s: State) {
        state = s
        warned = false
        endingPress = false
    }

    private mutating func end() { begin(.idle) }
}

/// The short-press hint shown next to the indicator. Our own wording.
public enum Hint {
    public static let shortPress = holdToTalk("fn")
    /// `key`: the hold-to-talk chord's label (`Key.label`), so a rebound chord gets its own name.
    public static func holdToTalk(_ key: String) -> String { "Hold \(key) to talk · double-tap for hands-free" }
    public static let seconds: TimeInterval = 3
    public static let cancelled = "Cancelled"
    public static let oneMinuteLeft = "1 minute left"
    public static let nothingToPaste = "Nothing to paste yet"
}
