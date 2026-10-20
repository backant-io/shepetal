import Foundation

/// What the user sees instead of a model name: the tier's default is the "standard" engine, anything else the
/// "alternative" one. Model names stay in logs, history rows and docs, never in the UI.
public enum EngineLabel {
    public static func of(_ modelName: String, tier: ModelTier = currentModelTier()) -> String {
        modelName == tier.primary.rawValue ? "standard" : "alternative"
    }

    /// The status line for the menu and Home.
    public static func status(_ modelName: String, tier: ModelTier = currentModelTier()) -> String {
        "On-device speech recognition (\(of(modelName, tier: tier)) engine)"
    }

    /// History's re-transcribe choices: the running engine first, then the tier's other one.
    public static func retryChoices(current: String?, tier: ModelTier = currentModelTier()) -> [(title: String, model: SpeechModel?)] {
        let others = [tier.primary, tier.fallback].compactMap { $0 }.filter { $0.rawValue != current }
        return (current.map { [("With the \(of($0, tier: tier)) engine (current)", nil)] } ?? [])
            + others.map { ("With the \(of($0.rawValue, tier: tier)) engine", $0) }
    }
}
