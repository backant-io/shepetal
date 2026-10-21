import AppKit
import ServiceManagement
import ShepetalCore

/// "Start at login" through `SMAppService.mainApp`. A person toggling it in Settings or ticking it in onboarding registers or
/// unregisters it; tests and the end-to-end run never do.
@MainActor
final class LoginItem: NSObject {
    private let say: (String) -> Void

    init(say: @escaping (String) -> Void) { self.say = say }

    var isOn: Bool { LoginItemMenu.state(Self.status).checked }

    func toggle() {
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
