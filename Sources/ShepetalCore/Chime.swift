import Foundation

/// Shepetal's own start, stop, hands-free lock and cancel sounds (dictation-input.md 2.7 and 4),
/// synthesized here, so there are no sound files. 16 kHz mono, at most 150 ms, peak 0.4 (about -8 dBFS),
/// 5 ms fades so nothing clicks.
public enum Chime: CaseIterable {
    case start, stop, lock, cancel

    public static let peak: Float = 0.4
    static let rate = Double(AudioStore.sampleRate)
    static let fade = AudioStore.sampleRate / 200  // 5 ms

    public var samples: [Float] {
        switch self {
        case .start: Self.tone(from: 660, to: 990, ms: 120)                // rising
        case .stop: Self.tone(from: 990, to: 660, ms: 120)                 // falling
        case .lock: Self.tone(from: 1175, to: 1175, ms: 45) + Self.silence(ms: 30) + Self.tone(from: 1175, to: 1175, ms: 45)
        case .cancel: Self.tone(from: 260, to: 220, ms: 140)               // low
        }
    }

    static func silence(ms: Int) -> [Float] { [Float](repeating: 0, count: AudioStore.sampleRate * ms / 1000) }

    /// A sine sweeping linearly from one frequency to another, faded in and out.
    static func tone(from f0: Double, to f1: Double, ms: Int) -> [Float] {
        let n = AudioStore.sampleRate * ms / 1000
        var phase = 0.0
        return (0..<n).map { i in
            let s = Float(sin(phase)) * peak * Float(min(1, Double(min(i, n - 1 - i)) / Double(fade)))
            phase += 2 * .pi * (f0 + (f1 - f0) * Double(i) / Double(n)) / rate
            return s
        }
    }
}

/// When each sound plays. fn-down opens the mic at once, but nothing is heard until the press is a
/// dictation: the start sound waits for the hold threshold, so a too-short tap and an fn shortcut
/// (fn+Delete, fn+arrow) stay silent (M-SND-1), and the cancel sound only follows a start the user heard.
public struct ChimeCue {
    private var heard = false

    public init() {}

    /// The sound for a gesture action, if any.
    public mutating func sound(for action: GestureAction) -> Chime? {
        switch action {
        case .start, .tooShort: heard = false; return nil
        case .lockHandsFree: heard = true; return .lock
        case .stop: heard = false; return .stop
        case .cancel: defer { heard = false }; return heard ? .cancel : nil
        }
    }

    /// The shell calls this `gesture.holdThreshold` after `.start`: the start sound, if fn is still held.
    public mutating func holdCheck(_ gesture: FnGesture, at t: TimeInterval) -> Chime? {
        guard !heard, case .holding(let since) = gesture.state, t - since >= gesture.holdThreshold else { return nil }
        heard = true
        return .start
    }
}
