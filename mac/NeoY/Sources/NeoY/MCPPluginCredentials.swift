import Foundation
import Security

enum NeoYMCPPluginCredentials {
    private static let service = "com.neox.neoy.mcp-plugin"
    private static let account = "credentials"

    struct Credentials: Equatable {
        let clientID: String
        let token: String
    }

    static func current() -> Credentials {
        let clientID = loadClientID() ?? createClientID()
        return Credentials(clientID: clientID, token: NeoYCoreAuth.token())
    }

    private static func loadClientID() -> String? {
        guard let data = keychainData(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let clientID = object["client_id"], !clientID.isEmpty else {
            return nil
        }
        return clientID
    }

    private static func createClientID() -> String {
        let clientID = randomID()
        guard let data = try? JSONSerialization.data(withJSONObject: ["client_id": clientID]) else {
            return clientID
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
        return clientID
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func randomID() -> String {
        "neoy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }


}
