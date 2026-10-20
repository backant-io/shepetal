import ShepetalSessionCore
import UIKit

/// Mic button that hands dictation to the Shepetal app and inserts the text it sends back.
final class KeyboardViewController: UIInputViewController {
    private let mic = UIButton(type: .system)
    private let label = UILabel()

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
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textAlignment = .center
        let globe = UIButton(type: .system)
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globe.isHidden = !needsInputModeSwitchKey
        let delete = UIButton(type: .system)
        delete.setImage(UIImage(systemName: "delete.left"), for: .normal)
        delete.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [globe, mic, delete])
        row.distribution = .equalCentering
        let stack = UIStackView(arrangedSubviews: [label, row])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            view.heightAnchor.constraint(equalToConstant: 180),
        ])
        SharedHandoff.observe(SharedHandoff.readyNotification) { [weak self] in self?.insertIfReady() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        insertIfReady()
    }

    @objc private func micTapped() {
        guard hasFullAccess else {
            label.text = "Turn on Allow Full Access for Shepetal in Settings."
            return
        }
        let current = SharedHandoff.update { $0 }
        if let id = sessionID, current.sessionID == id, current.phase == .recording {
            SharedHandoff.post(SharedHandoff.stopNotification)
            label.text = "Transcribing..."
            return
        }
        let id = UUID()
        sessionID = id
        SharedHandoff.update { $0.request(id) }
        label.text = "Opening Shepetal..."
        openApp(URL(string: "shepetal://dictate?id=\(id.uuidString)")!)
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    private func insertIfReady() {
        guard let id = sessionID else { return }
        let state = SharedHandoff.update { $0 }
        if state.sessionID == id, state.phase == .recording {
            label.text = "Listening. Tap the mic to finish."
        }
        guard let text = SharedHandoff.update({ $0.consume(id) }) else { return }
        sessionID = nil
        textDocumentProxy.insertText(text)
        label.text = nil
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
        label.text = "Open the Shepetal app to start dictating."
    }
}
