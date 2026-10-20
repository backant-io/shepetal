import FluidAudio
import Foundation
import ShepetalCore

protocol SpeechEngine: AnyObject {
    var name: String { get }
    /// `wav` is the saved recording holding the same samples.
    func transcribe(_ samples: [Float], wav: URL) async throws -> String
}

struct SpeechError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum Speech {
    /// The tier's default model, then its fallback. Never downloads anything.
    static func load(prefer: SpeechModel? = nil) async throws -> SpeechEngine {
        let tier = currentModelTier()
        var tried: [String] = []
        var models = [prefer ?? tier.primary]
        if let f = tier.fallback, f != models[0] { models.append(f) }
        for model in models {
            do { return try await engine(for: model) } catch { tried.append("\(model.rawValue): \(error.localizedDescription)") }
        }
        throw SpeechError("No speech model available. " + tried.joined(separator: "; "))
    }

    static func engine(for model: SpeechModel) async throws -> SpeechEngine {
        switch model {
        case .parakeetV3: return try await ParakeetEngine.load()
        case .whisperBaseEn, .whisperLargeV3Turbo: return try WhisperCppEngine(model)
        }
    }
}

/// Parakeet TDT 0.6B v3 through FluidAudio (CoreML, Neural Engine), from FluidAudio's model cache.
final class ParakeetEngine: SpeechEngine {
    let name = SpeechModel.parakeetV3.rawValue
    private let asr: AsrManager
    private let decoderLayers: Int

    static var directory: URL { AsrModels.defaultCacheDirectory(for: .v3) }
    static var isInstalled: Bool { AsrModels.modelsExist(at: directory, version: .v3) }

    private init(asr: AsrManager, decoderLayers: Int) {
        self.asr = asr
        self.decoderLayers = decoderLayers
    }

    static func load() async throws -> ParakeetEngine {
        // Checked first so FluidAudio never fetches missing files on its own.
        guard isInstalled else { throw SpeechError("Parakeet v3 is not downloaded (\(directory.path))") }
        let models = try await AsrModels.load(from: directory, version: .v3)
        let asr = AsrManager()
        try await asr.loadModels(models)
        let engine = ParakeetEngine(asr: asr, decoderLayers: models.version.decoderLayers)
        // The first inference compiles and warms the CoreML graph; do it before the user speaks.
        _ = try? await engine.transcribe([Float](repeating: 0, count: 16_000), wav: URL(fileURLWithPath: "/dev/null"))
        return engine
    }

    /// User action only: about 470 MB from Hugging Face into FluidAudio's cache.
    static func download() async throws {
        _ = try await AsrModels.download(version: .v3)
    }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        // A hold can end with under 300 ms of audio while the mic was still opening; Parakeet refuses that.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: AudioStore.sampleRate)
        return try await asr.transcribe(MicAudio.padded(samples, to: minimum), decoderState: &state).text
    }
}

/// The docs/models.md fallback: whisper.cpp's whisper-cli on the saved WAV.
/// ponytail: one process per dictation reloads the model (0.35 to 1.1 s here); keep a whisper.cpp
/// server or link libwhisper if the fallback has to meet the 700 ms bar.
/// Looks in <data>/models (whisper.cpp/whisper-cli and ggml-*.bin); SHEPETAL_WHISPER_CLI and
/// SHEPETAL_WHISPER_MODEL override the paths.
final class WhisperCppEngine: SpeechEngine {
    let name: String
    private let cli: URL
    private let model: URL

    init(_ m: SpeechModel) throws {
        let env = ProcessInfo.processInfo.environment
        cli = env["SHEPETAL_WHISPER_CLI"].map { URL(fileURLWithPath: $0) }
            ?? Paths.models.appendingPathComponent("whisper.cpp/whisper-cli")
        model = env["SHEPETAL_WHISPER_MODEL"].map { URL(fileURLWithPath: $0) }
            ?? Paths.models.appendingPathComponent("\(m.rawValue).bin")
        name = model.deletingPathExtension().lastPathComponent
        for url in [cli, model] where !FileManager.default.fileExists(atPath: url.path) {
            throw SpeechError("\(url.path) not found")
        }
    }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        let (cli, model) = (cli, model)
        return try await Task.detached {
            let p = Process()
            p.executableURL = cli
            p.arguments = ["-m", model.path, "-f", wav.path, "-l", "auto", "-nt", "-np"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw SpeechError("whisper-cli exited with \(p.terminationStatus)") }
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
        }.value
    }
}
