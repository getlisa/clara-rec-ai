import Foundation
import Security

/// Keychain-backed storage for the access and refresh tokens.
///
/// Deliberately not UserDefaults: the refresh token is a long-lived credential for a backend that
/// holds QuickBooks OAuth tokens for real companies, and UserDefaults is a plist inside the app
/// container that lands in unencrypted backups.
enum TokenStore {
    private static let service = "ai.justclara.ClaraAssistant.estimating"

    enum Key: String, CaseIterable {
        case accessToken
        case refreshToken
    }

    static func read(_ key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func write(_ value: String, for key: Key) {
        let query = baseQuery(for: key)
        let data = Data(value.utf8)

        // Update first: SecItemAdd fails with errSecDuplicateItem on an existing key.
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return
        }

        var insert = query
        insert[kSecValueData as String] = data
        // The tokens are only ever used while the technician is using the app, and this keeps them
        // off any backup that could restore them onto another device.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func delete(_ key: Key) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    static func clear() {
        Key.allCases.forEach(delete)
    }

    private static func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
