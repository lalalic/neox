import Foundation
import Security
import SwiftUI
import CryptoKit

/// Phone-side client of the existing authenticated Neo Remote MCP gateway.
/// No second SSH listener or public control server is created.
@MainActor
final class RemoteMCPClient: ObservableObject {
    struct SavedMac: Codable, Identifiable, Equatable {
        let url: String
        var name: String { URL(string: url)?.host ?? url }
        var id: String { url }
    }

    @Published private(set) var savedMacs: [SavedMac] = []
    @Published var endpoint = UserDefaults.standard.string(forKey: "remoteMCPURL") ?? ""
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    @Published var terminalOutput = ""

    private var terminalTool = ""
    private var sessionID: String?
    private var sessionGeneration = 0
    private var cursor = 0
    private var requestID = 0
    private let legacyCredentialKey = "com.neox.app.remote-mcp-token"
    private let savedMacsKey = "remoteMCPHistoryV1"
    private var bearer = ""

    init() {
        let urls = UserDefaults.standard.stringArray(forKey: savedMacsKey) ?? []
        savedMacs = urls.map { SavedMac(url: $0) }
        if !endpoint.isEmpty {
            let account = Self.credentialAccount(for: endpoint)
            if Self.readSecret(account: account) == nil,
               let old = Self.readSecret(account: legacyCredentialKey) {
                if (try? Self.saveSecret(old, account: account)) != nil {
                    Self.deleteSecret(account: legacyCredentialKey)
                }
            }
            if !savedMacs.contains(where: { $0.url == endpoint }) {
                savedMacs.insert(SavedMac(url: endpoint), at: 0)
            }
        } else if let first = savedMacs.first {
            endpoint = first.url
        }
        bearer = Self.readSecret(account: Self.credentialAccount(for: endpoint)) ?? ""
    }

    var hasCredential: Bool { !bearer.isEmpty }
    var isTerminalActive: Bool { sessionID != nil }
    var hasTerminalTool: Bool { !terminalTool.isEmpty }

    func openVNCTunnel() async throws -> VNCLoopbackRelay {
        guard connected, !bearer.isEmpty else { throw RemoteError.missingCredential }
        return try await VNCLoopbackRelay.start(url: remoteURL(path: "/vnc", scheme: "wss"), token: bearer)
    }

    /// Feature routes share the configured Neo Remote host and HTTPS gateway.
    /// Use WSS only for streaming endpoints such as VNC.
    func remoteURL(path: String, scheme: String = "https") throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("?"), !path.contains("#"),
              let source = URL(string: endpoint), source.scheme == "https",
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        else { throw RemoteError.invalidEndpoint }
        components.scheme = scheme
        components.path = path
        components.query = nil
        guard let result = components.url else { throw RemoteError.invalidEndpoint }
        return result
    }

    func saveConfiguration(url: String, token: String) throws {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: value),
              parsed.scheme == "https", parsed.host != nil,
              parsed.user == nil, parsed.password == nil, parsed.query == nil,
              parsed.fragment == nil else {
            throw RemoteError.invalidEndpoint
        }
        let normalized = value.hasSuffix("/mcp") ? value : value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/mcp"
        if !token.isEmpty {
            try Self.saveSecret(token, account: Self.credentialAccount(for: normalized))
            bearer = token
        } else if normalized != endpoint {
            bearer = Self.readSecret(account: Self.credentialAccount(for: normalized)) ?? ""
        }
        guard !bearer.isEmpty else { throw RemoteError.missingCredential }
        endpoint = normalized
        UserDefaults.standard.set(normalized, forKey: "remoteMCPURL")
        connected = false
    }

    func useSavedMac(_ mac: SavedMac) {
        endpoint = mac.url
        bearer = Self.readSecret(account: Self.credentialAccount(for: mac.url)) ?? ""
        connected = false
        error = nil
    }

    private func rememberCurrentMac() {
        savedMacs.removeAll { $0.url == endpoint }
        savedMacs.insert(SavedMac(url: endpoint), at: 0)
        UserDefaults.standard.set(savedMacs.map(\.url), forKey: savedMacsKey)
        UserDefaults.standard.set(endpoint, forKey: "remoteMCPURL")
    }

    func disconnect() {
        connected = false
        terminalTool = ""
    }

    func forgetCredential() {
        Self.deleteSecret(account: Self.credentialAccount(for: endpoint))
        savedMacs.removeAll { $0.url == endpoint }
        UserDefaults.standard.set(savedMacs.map(\.url), forKey: savedMacsKey)
        endpoint = savedMacs.first?.url ?? ""
        bearer = Self.readSecret(account: Self.credentialAccount(for: endpoint)) ?? ""
        UserDefaults.standard.set(endpoint, forKey: "remoteMCPURL")
        disconnect()
    }

    func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await rpc(method: "tools/list", params: [:])
            let tools = result["tools"] as? [[String: Any]] ?? []
            let names = tools.compactMap { $0["name"] as? String }
            // Federated Core tools keep their provider-defined names.
            terminalTool = names.first { $0 == "terminal" || $0.hasSuffix(".terminal") || $0 == "neo_terminal" } ?? ""
            connected = true
            rememberCurrentMac()
        } catch {
            connected = false
            self.error = error.localizedDescription
        }
    }

    func startTerminal() async {
        guard !terminalTool.isEmpty else { return }
        let generation = sessionGeneration
        busy = true
        defer { busy = false }
        do {
            let result = try await call(terminalTool, ["command": "start", "args": [
                "command": "/bin/zsh", "args": ["-i"], "cols": 80, "rows": 26,
                "label": "NeoX Remote"
            ]])
            guard let id = result["session_id"] as? String ?? result["sessionId"] as? String else {
                throw RemoteError.invalidResponse
            }
            if generation != sessionGeneration {
                _ = try? await call(terminalTool, [
                    "command": "close", "args": ["session_id": id]
                ])
                return
            }
            sessionID = id
            cursor = 0
            terminalOutput = ""
            await pollTerminal()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sendTerminal(_ input: String) async {
        guard let sessionID else { return }
        do {
            _ = try await call(terminalTool, [
                "command": "write", "args": ["session_id": sessionID, "data": input]
            ])
            await pollTerminal()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pollTerminal() async {
        guard let sessionID else { return }
        do {
            let result = try await call(terminalTool, [
                "command": "read",
                "args": ["session_id": sessionID, "cursor": cursor, "wait_ms": 0]
            ])
            if let output = result["text"] as? String ?? result["data"] as? String ?? result["output"] as? String {
                terminalOutput += output
            }
            if let next = result["nextCursor"] as? Int ?? result["next_cursor"] as? Int { cursor = next }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func closeTerminal() async {
        sessionGeneration += 1
        guard let sessionID else { return }
        self.sessionID = nil
        do {
            _ = try await call(terminalTool, [
                "command": "close", "args": ["session_id": sessionID]
            ])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        let response = try await rpc(method: "tools/call", params: ["name": name, "arguments": args])
        let blocks = response["content"] as? [[String: Any]] ?? []
        if response["isError"] as? Bool == true {
            throw RemoteError.toolFailure(blocks.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        }
        if let structured = response["structuredContent"] as? [String: Any] {
            return structured
        }
        if let text = blocks.compactMap({ $0["text"] as? String }).first,
           let data = text.data(using: .utf8),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dictionary
        }
        return response
    }

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: endpoint), url.scheme == "https", !bearer.isEmpty else {
            throw RemoteError.invalidEndpoint
        }
        requestID += 1
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": requestID, "method": method, "params": params
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteError.invalidResponse
        }
        if let fault = envelope["error"] as? [String: Any] {
            throw RemoteError.toolFailure(fault["message"] as? String ?? "Remote MCP error")
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw RemoteError.invalidResponse
        }
        return result
    }

    private static func credentialAccount(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "com.neox.app.remote-mcp-token." + digest
    }

    private static func deleteSecret(account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account
        ] as CFDictionary)
    }

    private static func readSecret(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: account,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveSecret(_ secret: String, account: String) throws {
        let query = [kSecClass as String: kSecClassGenericPassword,
                     kSecAttrAccount as String: account] as CFDictionary
        SecItemDelete(query)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw RemoteError.credentialSave
        }
    }
}

private enum RemoteError: LocalizedError {
    case invalidEndpoint, missingCredential, invalidResponse, toolsUnavailable, credentialSave
    case http(Int), toolFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter your Mac's secure address."
        case .missingCredential: "Enter your Mac's access code."
        case .invalidResponse: "Your Mac sent an unexpected reply."
        case .toolsUnavailable: "Commands are not available on this Mac."
        case .credentialSave: "Could not save the access code."
        case .http(let status): "Could not connect to your Mac (\(status))."
        case .toolFailure(let reason): reason
        }
    }
}
