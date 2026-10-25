import Foundation
import Security
import SwiftUI

/// Phone-side client of the existing authenticated Neo Remote MCP gateway.
/// No second SSH listener or public control server is created.
@MainActor
final class RemoteMCPClient: ObservableObject {
    @Published var endpoint = UserDefaults.standard.string(forKey: "remoteMCPURL") ?? ""
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    @Published var terminalOutput = ""

    private var terminalTool = ""
    private var sessionID: String?
    private var cursor = 0
    private var requestID = 0
    private let credentialKey = "com.neox.app.remote-mcp-token"
    private var bearer = ""

    init() {
        bearer = Self.readSecret(account: credentialKey) ?? ""
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
            try Self.saveSecret(token, account: credentialKey)
            bearer = token
        }
        guard !bearer.isEmpty else { throw RemoteError.missingCredential }
        endpoint = normalized
        UserDefaults.standard.set(normalized, forKey: "remoteMCPURL")
        connected = false
    }

    func disconnect() {
        connected = false
        terminalTool = ""
    }

    func forgetCredential() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: credentialKey
        ] as CFDictionary)
        bearer = ""
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
        } catch {
            connected = false
            self.error = error.localizedDescription
        }
    }

    func startTerminal() async {
        guard !terminalTool.isEmpty else { return }
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
        guard let sessionID else { return }
        do {
            _ = try await call(terminalTool, [
                "command": "close", "args": ["session_id": sessionID]
            ])
            self.sessionID = nil
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

    private static func readSecret(account: String) -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
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
        case .invalidEndpoint: "Enter a valid HTTPS Neo MCP endpoint."
        case .missingCredential: "Enter the Neo access token."
        case .invalidResponse: "Unexpected Remote MCP response."
        case .toolsUnavailable: "Terminal is not enabled for remote access."
        case .credentialSave: "Could not store the credential securely."
        case .http(let status): "Remote MCP HTTP \(status)."
        case .toolFailure(let reason): reason
        }
    }
}
