import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.toynessit.MailMate"

    @discardableResult
    static func save(_ key: String, for provider: ProviderKind) -> Bool {
        let data = key.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            Log.write("Keychain delete failed for \(provider.rawValue): OSStatus \(deleteStatus)")
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.write("Keychain save failed for \(provider.rawValue): OSStatus \(addStatus)")
            return false
        }
        return true
    }

    static func load(for provider: ProviderKind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound && status != errSecSuccess {
                Log.write("Keychain load failed for \(provider.rawValue): OSStatus \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
