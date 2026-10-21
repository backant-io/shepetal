import Foundation

/// How dictated text is written into an app (F33). Formatted runs the rule cleanup, the local cleanup model
/// when it is loaded, and spoken dates as numbers. Raw inserts the words as heard.
public enum FormatMode: String, CaseIterable, Sendable {
    case formatted, raw
}

/// Formatting per app (F33): a default for every app plus a choice per bundle id, kept in UserDefaults like
/// `AppBlockList`. It is read on every dictation, so a change in Settings applies to the next one.
public struct AppFormat {
    public static let defaultKey = "formatDefault", appsKey = "formatByApp"
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Formatted unless the user picked Raw for all apps.
    public var defaultMode: FormatMode {
        get { defaults.string(forKey: Self.defaultKey).flatMap(FormatMode.init) ?? .formatted }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.defaultKey) }
    }

    /// Bundle id → that app's own choice. Read entry by entry: a bad value drops only itself.
    public var apps: [String: FormatMode] {
        (defaults.dictionary(forKey: Self.appsKey) ?? [:]).compactMapValues { ($0 as? String).flatMap(FormatMode.init) }
    }

    /// nil puts the app back on the default.
    public func set(_ mode: FormatMode?, for bundleId: String) {
        guard !bundleId.isEmpty else { return }
        var apps = apps
        apps[bundleId] = mode
        defaults.set(apps.mapValues(\.rawValue), forKey: Self.appsKey)
    }

    /// The app's own choice, else the default. No front app (an empty bundle id) gets the default.
    public func mode(for bundleId: String) -> FormatMode { apps[bundleId] ?? defaultMode }

    /// Everything between speech-to-text and insertion, shared by dictation and re-transcription. The non-speech
    /// tags always go. Formatted then runs the rules, the local cleanup model (given `context`, the text around the
    /// cursor, F24, and My voice, F38), spoken dates (docs/text-rules.md) and the app category's style (F37); Raw skips all four, since
    /// it means no formatting. The personal dictionary (F39) runs in both modes, last, since it fixes what was heard,
    /// not how it is written, and its text is inserted as written. InsertionRules fits the result to the cursor afterwards.
    public static func finish(_ raw: String, mode: FormatMode, model: CleanupModel?, vocabulary: Vocabulary,
                              style: Style = .formal, context: CleanupContext = .none,
                              voice: MyVoice = .none) -> (text: String, usedModel: Bool) {
        guard mode == .formatted else { return (vocabulary.apply(asHeard(raw)), false) }
        let cleaned = SmartCleanup.apply(SpeechGuard.stripTags(raw), model: model, context: context, voice: voice)
        return (vocabulary.apply(Styles.apply(style, to: Dates.apply(cleaned.text))), cleaned.usedModel)
    }

    /// The words as heard, for Raw and Show raw (F48): the non-speech tags removed, and the run of spaces a tag
    /// leaves mid-text collapsed, which Formatted gets from the rule cleanup.
    public static func asHeard(_ raw: String) -> String {
        SpeechGuard.stripTags(raw).replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
