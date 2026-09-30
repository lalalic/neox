import Foundation
import Security

enum NeoYMCPPluginCredentials {
    private static let service = "com.neox.neoy.mcp-plugin"
    private static let account = "oauth"

    static func load() -> (clientID: String, token: String) {
        guard let data = keychainData() else { return ("", "") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        return (object?["client_id"] ?? "", object?["token"] ?? "")
    }

    static func save(clientID: String, token: String) {
        let object = ["client_id": clientID, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }
}
