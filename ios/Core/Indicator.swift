import UIKit

/// The 🤫 indicator. iOS allows no system-wide overlay, so it sits in the keyboard's bottom-left corner:
/// about 18 pt, inset 8 pt, always shown, with the dictation state (including errors) next to it.
public enum Indicator {
    public static let emoji = "🤫"

    /// Pins the indicator into `view` and returns the label for the state text next to it.
    @MainActor
    public static func install(in view: UIView) -> UILabel {
        let psst = UILabel()
        psst.text = emoji
        psst.font = .systemFont(ofSize: 18)
        psst.accessibilityLabel = "Shepetal"
        let status = UILabel()
        status.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 0
        for label in [psst, status] {
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        NSLayoutConstraint.activate([
            psst.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            psst.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: psst.trailingAnchor, constant: 4),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            status.lastBaselineAnchor.constraint(equalTo: psst.lastBaselineAnchor),
        ])
        return status
    }
}
