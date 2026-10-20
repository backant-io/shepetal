import AVFoundation
import ShepetalCore

/// Converts any input format to the 16 kHz mono Float32 the models take.
final class Resampler {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioStore.sampleRate),
                                      channels: 1, interleaved: false)!
    private let converter: AVAudioConverter

    init?(from input: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: Self.format) else { return nil }
        c.downmix = true
        converter = c
    }

    /// Pass nil at the end to flush what the resampler still holds.
    func convert(_ input: AVAudioPCMBuffer?) -> [Float] {
        let ratio = Self.format.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard let input, !given else {
                status.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// Reads a whole audio file through the same conversion the microphone uses.
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let r = Resampler(from: file.processingFormat),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw SpeechError("Cannot convert \(url.lastPathComponent)")
        }
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buf)
            samples += r.convert(buf)
        }
        return samples + r.convert(nil)
    }
}

/// Opens the mic for each dictation (so the macOS mic indicator is on only while dictating)
/// and collects 16 kHz mono samples. Opening the mic can take half a second or more, and fn is read on the
/// main thread, so every engine call runs on `queue`: `start` returns at once and `stop` waits for it.
/// The one capture runs from the first fn press through hands-free; nothing restarts it.
final class Recorder {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "io.backant.shepetal.mic")
    private let lock = NSLock()
    private var samples: [Float] = []
    private var resampler: Resampler?
    /// On the main queue, when the mic did not open. The recording then ends with no audio.
    var onError: ((String) -> Void)?

    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func start() {
        queue.async { [self] in
            do { try open() } catch {
                let message = "Microphone: \(error.localizedDescription)"
                DispatchQueue.main.async { self.onError?(message) }
            }
        }
    }

    private func open() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        lock.withLock { samples = []; resampler = nil }
        guard format.sampleRate > 0, format.channelCount > 0, let r = Resampler(from: format) else {
            throw SpeechError("No microphone")
        }
        lock.withLock { resampler = r }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.withLock { self.samples += self.resampler?.convert(buf) ?? [] }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() -> [Float] {
        queue.sync {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        return lock.withLock {
            defer { resampler = nil }
            return samples + (resampler?.convert(nil) ?? [])
        }
    }
}
