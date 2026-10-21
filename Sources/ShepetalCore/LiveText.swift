import Foundation

/// F13: the words so far, next to 🤫 while a dictation records. A partial is a preview only: the text inserted is
/// always the final pass over the whole recording, into the window that kept focus (rule 8). Pure: the caller
/// gives the clock, the samples and the engine's text. At most one pass a second, never two at once, on the last
/// 10 s, and only when that audio is above the speech floor.
public struct LiveText {
    /// Settings, "Show words while you speak". Unset means `defaultOn`.
    public static let key = "liveText"
    /// Off until Pavel picks the default; flipping it is this one line.
    public static let defaultOn = false
    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultOn
    }

    public static let interval: TimeInterval = 1
    /// The end of the recording a pass reads. The speech engine runs one pass at a time, so the final pass waits
    /// for a partial still running; a short window keeps that wait short.
    public static let windowSamples = 10 * AudioStore.sampleRate
    public static let tailLength = 40

    /// A partial to run: `samples` through the engine, then `finished(id, text:)`.
    public struct Pass {
        public let id: Int
        public let samples: [Float]
    }

    private var dictation = 0  // bumped by start and stop, so a pass from before is late
    private var active = false
    private var running = false
    private var lastPass: TimeInterval = 0

    public init() {}

    /// Recording began at `t`: the first pass comes a second later.
    public mutating func start(at t: TimeInterval) {
        dictation += 1
        active = true
        running = false
        lastPass = t
    }

    /// Release, Esc, too short or a mic end: a pass still running is dropped when it returns.
    public mutating func stop() {
        dictation += 1
        active = false
        running = false
    }

    /// The pass to run now, or nil: not recording, a pass still running, under a second since the last one, or
    /// no speech yet in the window (tried again at the next call, not a second later).
    public mutating func pass(_ samples: [Float], at t: TimeInterval) -> Pass? {
        guard active, !running, t - lastPass >= Self.interval else { return nil }
        let window = Array(samples.suffix(Self.windowSamples))
        guard SpeechGuard.isSpeech(window) else { return nil }
        running = true
        lastPass = t
        return Pass(id: dictation, samples: window)
    }

    /// The pass came back (`text` nil when it failed). Returns the text to show, or nil to leave the label as it
    /// is: the dictation ended meanwhile, the pass failed, or it heard no words.
    public mutating func finished(_ id: Int, text: String?) -> String? {
        guard id == dictation else { return nil }
        running = false
        guard let text else { return nil }
        let tail = Self.tail(text)
        return tail.isEmpty ? nil : tail
    }

    /// The last words of `text` that fit in `length` characters, after "…" when words were cut off.
    /// A last word longer than that keeps its end.
    public static func tail(_ text: String, length: Int = tailLength) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        var out = ""
        var used = 0
        for word in words.reversed() {
            let next = out.isEmpty ? String(word) : word + " " + out
            guard next.count <= length else { break }
            out = next
            used += 1
        }
        if out.isEmpty, let last = words.last { return "…" + last.suffix(length) }
        return used < words.count ? "…" + out : out
    }
}
