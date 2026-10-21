import AVFoundation
import ShepetalCore

/// Pavel's rule for the Mac mic (#75): always Voice Isolation, and never the Mic Mode picker. macOS lets only the
/// user set the system mic mode, and Apple's voice processing would list Shepetal in that picker and hand the
/// choice to the user, so Shepetal never turns it on. Instead every dictation goes through Apple's own
/// sound-isolation effect (AUSoundIsolation, the filter behind Voice Isolation) before the speech model. The
/// kept WAV is the raw recording; only what the model hears is isolated.
enum VoiceIsolation {
    private static let effect = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x766f_6973,  // vois
                                                          componentManufacturer: kAudioUnitManufacturer_Apple,
                                                          componentFlags: 0, componentFlagsMask: 0)

    /// Wet/dry mix in percent: 100 is the effect alone, 0 skips it. A calibration knob for real rooms (M-MIC-6):
    /// `defaults write io.backant.shepetal voiceIsolationMix -float <0-100>`. On the e2e clips 100 costs 3.1% WER
    /// and 50 costs nothing (#75).
    static var mix: Float {
        let knob = UserDefaults.standard.object(forKey: "voiceIsolationMix") as? Float
        return min(100, max(0, knob ?? 100))
    }

    /// The samples (16 kHz mono) with the voice isolated, the same length. If the effect is missing or fails,
    /// the raw samples: a dictation never fails because of it.
    static func apply(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty, mix > 0 else { return samples }
        do { return try render(samples) } catch {
            NSLog("shepetal: voice isolation: %@", String(describing: error))
            return samples
        }
    }

    private static func render(_ samples: [Float]) throws -> [Float] {
        let format = Resampler.format
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let iso = AVAudioUnitEffect(audioComponentDescription: effect)
        engine.attach(player)
        engine.attach(iso)
        iso.auAudioUnit.parameterTree?.parameter(withAddress: 0)?.value = mix
        engine.connect(player, to: iso, format: format)
        engine.connect(iso, to: engine.mainMixerNode, format: format)
        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try engine.start()
        defer { engine.stop() }
        // The effect delays its output by its latency: feed that much silence after the samples, then drop it.
        let latency = Int(iso.auAudioUnit.latency * format.sampleRate)
        let total = samples.count + latency
        let input = samples + [Float](repeating: 0, count: latency + Int(chunk))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count)),
              let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw SpeechError("No buffer for voice isolation")
        }
        buffer.frameLength = buffer.frameCapacity
        input.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        player.scheduleBuffer(buffer, at: nil)
        player.play()
        var rendered: [Float] = []
        rendered.reserveCapacity(total)
        while rendered.count < total {
            let status = try engine.renderOffline(min(chunk, AVAudioFrameCount(total - rendered.count)), to: out)
            guard status == .success else { throw SpeechError("Voice isolation stopped (\(status.rawValue))") }  // not shown: apply logs it
            rendered += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
        }
        return Array(rendered.dropFirst(latency))
    }
}
