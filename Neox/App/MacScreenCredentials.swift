import CryptoKit
import Foundation
import Security

/// Screen-sharing credentials stay on this iPhone and are scoped to one Mac.
enum MacScreenCredentials {
    private static func account(for endpoint: String) -> String {
        let digest = SHA256.hash(data: Data(endpoint.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "com.neox.app.mac-screen." + digest
    }

    static func load(for endpoint: String) -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(for: endpoint),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let values = try? JSONDecoder().decode(Credentials.self, from: data)
        else { return nil }
        return (values.username, values.password)
    }

    static func save(username: String, password: String, for endpoint: String) throws {
        let data = try JSONEncoder().encode(Credentials(username: username, password: password))
        delete(for: endpoint)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(for: endpoint),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw CredentialError.saveFailed
        }
    }

    static func delete(for endpoint: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(for: endpoint)
        ]
        SecItemDelete(query as CFDictionary)
    }

    private struct Credentials: Codable {
        let username: String
        let password: String
    }

    private enum CredentialError: LocalizedError {
        case saveFailed
        var errorDescription: String? { "Could not remember your Mac login." }
    }
}
