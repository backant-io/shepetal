import ActivityKit
import UIKit

/// The 🤫 indicator. iOS allows no system-wide overlay, so it sits in the keyboard's bottom-left corner:
/// about 18 pt, inset 8 pt, always shown, with a state ring around it and the state text (including
/// errors) next to it. While a dictation runs, the app also shows it in a Live Activity.
@MainActor
public final class Indicator {
    /// The ring colors of the Mac indicator (`Sources/Shepetal/Indicator.swift`). The iPhone has no
    /// hold-to-talk, so it has no separate hands-free state.
    public enum Mode: String, Codable, Hashable {
        case idle, recording, processing, error

        public var color: UIColor? {
            switch self {
            case .idle: nil
            case .recording: .systemRed
            case .processing: .systemBlue
            case .error: .systemYellow
            }
        }

        /// How long a Live Activity may show this state without an update before it is stale (the app died):
        /// a recording runs up to its cap, transcription has the handoff timeout. Nil: never stale.
        public var staleAfter: TimeInterval? {
            switch self {
            case .recording: Handoff.maxRecording + Handoff.timeout
            case .processing: Handoff.timeout
            case .idle, .error: nil
            }
        }

        /// The state word in the Live Activity and the Dynamic Island.
        public var title: String {
            switch self {
            case .idle: "Ready"
            case .recording: "Listening"
            case .processing: "Transcribing"
            case .error: "Not inserted"
            }
        }
    }

    public static let emoji = "🤫"
    static let ring: CGFloat = 24

    let psst = UILabel()
    /// The state text next to 🤫.
    public let status = UILabel()

    /// Pins the indicator into `view`'s bottom-left corner.
    public init(in view: UIView) {
        psst.text = Self.emoji
        psst.font = .systemFont(ofSize: 18)
        psst.textAlignment = .center
        psst.accessibilityLabel = "Shepetal"
        psst.layer.cornerRadius = Self.ring / 2
        status.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 0
        for label in [psst, status] {
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        NSLayoutConstraint.activate([
            psst.widthAnchor.constraint(equalToConstant: Self.ring),
            psst.heightAnchor.constraint(equalToConstant: Self.ring),
            psst.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            psst.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: psst.trailingAnchor, constant: 4),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            status.lastBaselineAnchor.constraint(equalTo: psst.lastBaselineAnchor),
        ])
    }

    public func show(_ mode: Mode, _ text: String?) {
        status.text = text
        psst.layer.borderWidth = mode.color == nil ? 0 : 2
        psst.layer.borderColor = mode.color?.cgColor
    }
}

/// The Live Activity the app shows while a dictation runs: 🤫 with the state ring on the lock screen
/// and in the Dynamic Island. The widget extension draws it; the app starts, updates and ends it.
public struct DictationActivity: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var mode: Indicator.Mode
        public init(mode: Indicator.Mode) { self.mode = mode }
    }

    public init() {}
}
