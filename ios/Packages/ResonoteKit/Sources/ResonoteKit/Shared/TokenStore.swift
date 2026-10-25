import Foundation
import Security

/// Keeps the bearer token in the Keychain, shared with the extensions through the
/// App Group (an App Group id doubles as a keychain access group with no extra
/// entitlement), so the widget, controls, and share extension can act as the person.
public struct TokenStore: Sendable {
    public static let shared = TokenStore()

    private let service = "dev.nmaass.resonote.session"
    private let account = "bearer"
    private let accessGroup: String?

    public init(accessGroup: String? = AppGroup.identifier) {
        self.accessGroup = accessGroup.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func read() -> String? {
        if let accessGroup, let token = read(group: accessGroup) { return token }
        return read(group: nil)
    }

    public func save(_ token: String) {
        delete()
        guard let data = token.data(using: .utf8) else { return }
        if let accessGroup, add(data, group: accessGroup) == errSecSuccess { return }
        // Missing keychain-sharing entitlement (e.g. an unsigned simulator build): keep it app-local.
        _ = add(data, group: nil)
    }

    public func delete() {
        for group in [accessGroup, nil] {
            var query = baseQuery(group: group)
            query.removeValue(forKey: kSecReturnData as String)
            SecItemDelete(query as CFDictionary)
        }
    }

    private func baseQuery(group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private func read(group: String?) -> String? {
        var query = baseQuery(group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func add(_ data: Data, group: String?) -> OSStatus {
        var query = baseQuery(group: group)
        query[kSecValueData as String] = data
        // Widgets and controls run while the phone is locked; the token must stay readable after first unlock.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }
}
