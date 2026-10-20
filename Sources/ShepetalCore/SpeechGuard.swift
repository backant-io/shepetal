import Foundation

/// Keeps recordings with no speech away from the model and from the cursor (F51). Too-short presses
/// are already dropped by the hold threshold; this covers silence and the non-speech tags a model prints.
public enum SpeechGuard {
    /// Loudest 100 ms window, so one short word in a long hands-free recording still counts.
    public static let window = AudioStore.sampleRate / 10

    /// ponytail: -60 dBFS was picked on `say` audio and digital silence only. It needs calibrating on real
    /// mics (room noise on a built-in mic, a whisper, a headset); add a VAD model if one floor cannot fit them.
    /// Knob: `defaults write io.backant.shepetal speechFloorDb -float -55`.
    public static var floorDb: Float {
        (UserDefaults.standard.object(forKey: "speechFloorDb") as? NSNumber)?.floatValue ?? -60
    }

    /// RMS of the loudest window in dBFS (a full-scale square wave is 0). Silence is -infinity.
    public static func levelDb(_ samples: [Float]) -> Float {
        var loudest: Float = 0  // mean square
        for start in stride(from: 0, to: samples.count, by: window) {
            let w = samples[start..<min(start + window, samples.count)]
            loudest = max(loudest, w.reduce(Float(0)) { $0 + $1 * $1 } / Float(w.count))
        }
        return 10 * log10(loudest)
    }

    public static func isSpeech(_ samples: [Float], floorDb: Float = floorDb) -> Bool {
        levelDb(samples) >= floorDb
    }

    /// Drops the tags speech models print for non-speech: "[BLANK_AUDIO]", "[Music]", "(silence)".
    /// Parenthesized text goes only when it names a sound, so dictated "(page 2)" stays.
    public static func stripTags(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\[[^\]]*\]|(?i)\([^)]*\b(?:silence|music|noise|inaudible|applause|laugh\w*|blank_audio)\b[^)]*\)"#,
                                 with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
