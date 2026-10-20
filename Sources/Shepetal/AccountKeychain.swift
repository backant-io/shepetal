import Foundation
import Security

/// The account token, in the login Keychain (service io.backant.shepetal.account). Nothing else is stored there.
struct TokenStore {
    var read: () -> String?
    var write: (String) throws -> Void
    var delete: () -> Void

    /// SHEPETAL_KEYCHAIN_SERVICE overrides the service; a SHEPETAL_HOME run (tests, screenshots) gets its own,
    /// so it never reads or replaces the real sign-in.
    static var keychainService: String {
        let env = ProcessInfo.processInfo.environment
        return env["SHEPETAL_KEYCHAIN_SERVICE"]
            ?? (env["SHEPETAL_HOME"] == nil ? "io.backant.shepetal.account" : "io.backant.shepetal.account.dev")
    }

    static func keychain(service: String = keychainService) -> TokenStore {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "token"]
        return TokenStore(
            read: {
                var query = base
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var out: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
                return String(data: data, encoding: .utf8)
            },
            write: { token in
                SecItemDelete(base as CFDictionary)
                var item = base
                item[kSecValueData as String] = Data(token.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let status = SecItemAdd(item as CFDictionary, nil)
                guard status == errSecSuccess else {
                    throw SpeechError("Could not save the sign-in to the Keychain (\(status))")
                }
            },
            delete: { SecItemDelete(base as CFDictionary) })
    }

    /// Tests.
    static func memory() -> TokenStore {
        final class Box: @unchecked Sendable { var token: String? }
        let box = Box()
        return TokenStore(read: { box.token }, write: { box.token = $0 }, delete: { box.token = nil })
    }
}
