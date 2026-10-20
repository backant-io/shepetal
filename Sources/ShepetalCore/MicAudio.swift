import Foundation

/// When an fn change happened, from the event's own timestamp (nanoseconds of uptime, the clock that
/// `ProcessInfo.systemUptime` reads). The main thread can read an event late: opening the mic held it past the
/// 500 ms hold threshold on Pavel's Mac, so the release of a double-tap's first tap counted as a hold and the
/// recording stopped with no audio. The gesture is timed by when the key moved, not by when it was read.
/// A missing, future or very old timestamp falls back to `now`.
public enum FnClock {
    public static let maxAge: TimeInterval = 5

    public static func seconds(timestamp: UInt64, now: TimeInterval) -> TimeInterval {
        let t = TimeInterval(timestamp) / 1e9
        guard t > now - maxAge, t < now + 0.1 else { return now }
        return min(t, now)
    }
}

public enum MicAudio {
    /// Said instead of "No speech heard" when the recording has no samples at all (the mic did not open, or
    /// opened after fn was released). SpeechGuard (F51) still decides: the outcome is no_speech either way.
    public static let noAudio = "No audio from the microphone"

    /// Trailing zeros up to `count` samples, for a model that rejects shorter input.
    public static func padded(_ samples: [Float], to count: Int) -> [Float] {
        samples + [Float](repeating: 0, count: max(0, count - samples.count))
    }
}
