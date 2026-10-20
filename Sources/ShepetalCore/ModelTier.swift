import Foundation

public enum SpeechModel: String, Equatable {
    case parakeetV3 = "parakeet-tdt-0.6b-v3"          // FluidAudio CoreML, Apple Silicon only
    case whisperBaseEn = "ggml-base.en-q5_1"          // whisper.cpp
    case whisperLargeV3Turbo = "ggml-large-v3-turbo-q5_0"  // whisper.cpp
}

public struct ModelTier: Equatable {
    public let primary: SpeechModel
    public let fallback: SpeechModel?
}

/// The Mac rows of the tier table in docs/models.md.
/// Fallbacks all run on whisper.cpp so the Mac needs one fallback runtime.
public func modelTier(appleSilicon: Bool, ramGB: Int) -> ModelTier {
    guard appleSilicon else { return ModelTier(primary: .whisperBaseEn, fallback: nil) }
    if ramGB < 16 { return ModelTier(primary: .parakeetV3, fallback: .whisperBaseEn) }
    return ModelTier(primary: .parakeetV3, fallback: .whisperLargeV3Turbo)
}

/// This machine's tier.
public func currentModelTier() -> ModelTier {
    #if arch(arm64)
    let arm = true
    #else
    let arm = false
    #endif
    return modelTier(appleSilicon: arm, ramGB: Int(ProcessInfo.processInfo.physicalMemory >> 30))
}
