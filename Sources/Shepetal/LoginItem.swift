import AppKit
import ServiceManagement
import ShepetalCore

/// "Start at login" through `SMAppService.mainApp`. A person toggling the menu item, or the installer (`--postinstall`), registers or
/// unregisters it; tests and the end-to-end run never do.
@MainActor
final class LoginItem: NSObject {
    private let say: (String) -> Void

    init(say: @escaping (String) -> Void) { self.say = say }

    var menuItem: NSMenuItem {
        let i = NSMenuItem(title: "Start at login", action: #selector(toggle), keyEquivalent: "")
        i.target = self
        i.state = LoginItemMenu.state(Self.status).checked ? .on : .off
        return i
    }

    @objc private func toggle() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            say("Start at login: \(error.localizedDescription)")
        }
        if let message = LoginItemMenu.state(Self.status).message {
            say(message)
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        default: .notFound
        }
    }
}
