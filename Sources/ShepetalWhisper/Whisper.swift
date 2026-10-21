import Foundation
import ShepetalCore
import whisper

/// A whisper.cpp model in this process, with Metal, loaded once and kept: a dictation no longer starts a
/// whisper-cli process that reloads the model each time (#11). One transcription at a time, by its own lock.
public final class WhisperModel: @unchecked Sendable {
    public let name: String
    /// False for the English-only models (".en"): they are always told English.
    public let multilingual: Bool
    private let ctx: OpaquePointer
    private let lock = NSLock()
    private let threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))

    public struct WhisperError: LocalizedError {
        public let errorDescription: String?
    }

    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw WhisperError(errorDescription: "\(path) not found") }
        if ProcessInfo.processInfo.environment["SHEPETAL_WHISPER_LOG"] == nil { whisper_log_set({ _, _, _ in }, nil) }
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        guard let c = whisper_init_from_file_with_params(path, cp) else {
            throw WhisperError(errorDescription: "whisper.cpp could not load \(path)")
        }
        Self.track(c)
        ctx = c
        multilingual = whisper_is_multilingual(c) != 0
        name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    deinit { Self.close(ctx) }

    // ggml's Metal device aborts at exit while a model still holds GPU memory (LlamaCleanup has the same), so a
    // model still open when the process exits is freed first.
    nonisolated(unsafe) private static var open: Set<OpaquePointer> = []
    private static let openLock = NSLock()
    private static let freeAtExit: Void = {
        atexit { for c in openLock.withLock({ Array(WhisperModel.open) }) { WhisperModel.close(c) } }
    }()

    private static func track(_ ctx: OpaquePointer) {
        _ = freeAtExit
        _ = openLock.withLock { open.insert(ctx) }
    }

    private static func close(_ ctx: OpaquePointer) {
        guard openLock.withLock({ open.remove(ctx) }) != nil else { return }
        whisper_free(ctx)
    }

    /// The text of 16 kHz mono `samples`, and the language it was written in. `languages` are the codes the user
    /// chose: none lets whisper detect, one is told to it, and of several the most likely one is (`pickLanguage`),
    /// even when a language outside them ranks first (#31). `prompt` is the dictionary hint.
    public func transcribe(_ samples: [Float], languages: [String], prompt: String?) throws -> (text: String, language: String) {
        lock.lock()
        defer { lock.unlock() }
        let language: String
        if !multilingual {
            language = "en"
        } else if languages.count > 1 {
            language = pickLanguage(probs: try probabilities(samples), allowed: languages) ?? "auto"
        } else {
            language = languages.first ?? "auto"
        }
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = threads
        p.no_timestamps = true
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.print_special = false
        p.translate = false
        let status: Int32 = language.withCString { lang in
            p.language = lang
            guard let prompt else { return whisper_full(ctx, p, samples, Int32(samples.count)) }
            return prompt.withCString { text in
                p.initial_prompt = text
                return whisper_full(ctx, p, samples, Int32(samples.count))
            }
        }
        guard status == 0 else { throw WhisperError(errorDescription: "whisper.cpp stopped with code \(status)") }
        let text = (0..<whisper_full_n_segments(ctx)).compactMap { i in
            whisper_full_get_segment_text(ctx, i).map { String(cString: $0).trimmingCharacters(in: .whitespaces) }
        }.filter { !$0.isEmpty }.joined(separator: " ")
        let heard = language == "auto" ? whisper_lang_str(whisper_full_lang_id(ctx)).map { String(cString: $0) } ?? "auto" : language
        return (text, heard)
    }

    /// Each language's probability on the first 30 s, by whisper's code.
    public func languageProbabilities(_ samples: [Float]) throws -> [String: Float] {
        lock.lock()
        defer { lock.unlock() }
        return try probabilities(samples)
    }

    private func probabilities(_ samples: [Float]) throws -> [String: Float] {
        guard whisper_pcm_to_mel(ctx, samples, Int32(samples.count), threads) == 0 else {
            throw WhisperError(errorDescription: "whisper.cpp could not read the audio")
        }
        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard whisper_lang_auto_detect(ctx, 0, threads, &probs) >= 0 else {
            throw WhisperError(errorDescription: "whisper.cpp could not detect the language")
        }
        var out: [String: Float] = [:]
        for (i, p) in probs.enumerated() {
            if let code = whisper_lang_str(Int32(i)) { out[String(cString: code)] = p }
        }
        return out
    }
}
