import ShepetalSessionCore
import UIKit

/// Mic button that hands dictation to the Shepetal app and inserts the text it sends back.
final class KeyboardViewController: UIInputViewController {
    private let mic = UIButton(type: .system)
    /// 🤫 in the bottom-left corner, with the state ring and text.
    private var indicator: Indicator!

    /// The keyboard process is torn down while the user is in the app, so its session id
    /// lives in the extension's own defaults. Only text for this id is ever inserted.
    private var sessionID: UUID? {
        get { UserDefaults.standard.string(forKey: "sessionID").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "sessionID") }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        mic.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32)), for: .normal)
        mic.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        let globe = UIButton(type: .system)
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globe.isHidden = !needsInputModeSwitchKey
        let delete = UIButton(type: .system)
        delete.setImage(UIImage(systemName: "delete.left"), for: .normal)
        delete.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [globe, mic, delete])
        row.distribution = .equalCentering
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        indicator = Indicator(in: view)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            row.bottomAnchor.constraint(lessThanOrEqualTo: indicator.status.topAnchor, constant: -8),
            view.heightAnchor.constraint(equalToConstant: 180),
        ])
        SharedHandoff.observe(SharedHandoff.readyNotification) { [weak self] in self?.refresh() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    @objc private func micTapped() {
        guard hasFullAccess else {
            indicator.show(.error, "Turn on Allow Full Access for Shepetal in Settings.")
            return
        }
        // The app acts on the stop notification only when the shared state asks it to stop this recording.
        if let id = sessionID, SharedHandoff.update({ $0.requestStop(id) }) {
            SharedHandoff.post(SharedHandoff.stopNotification)
            indicator.show(.processing, "Transcribing...")
            return
        }
        // A new request supersedes any recording still running; the app stops that one within a second.
        let id = UUID()
        sessionID = id
        // The result is inserted only into this same field.
        let document = textDocumentProxy.documentIdentifier
        SharedHandoff.update { $0.request(id, document: document) }
        indicator.show(.processing, "Opening Shepetal...")
        openApp(URL(string: "shepetal://dictate?id=\(id.uuidString)")!)
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    /// Inserts a ready result, and shows next to 🤫 how the session stands or why it ended without text.
    private func refresh() {
        guard let id = sessionID else { return }
        let document = textDocumentProxy.documentIdentifier
        if let text = SharedHandoff.update({ $0.consume(id, document: document) }) {
            textDocumentProxy.insertText(text)
        }
        let state = SharedHandoff.read()
        indicator.show(state.indicatorMode(for: id), state.keyboardStatus(for: id))
        if state.sessionID != id || ![.requested, .recording, .transcribing].contains(state.phase) {
            sessionID = nil // finished; the message stays until the next dictation
        }
    }

    /// Extensions cannot call UIApplication.shared; walk the responder chain to the host's UIApplication.
    private func openApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(url)
                return
            }
            responder = current.next
        }
        indicator.show(.error, "Open the Shepetal app to start dictating.")
    }
}
