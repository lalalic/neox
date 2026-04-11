import Foundation

/// Lightweight Discord bridge client.
/// Connects to the relay server via WebSocket, registers Discord channels,
/// and forwards incoming Discord messages to the app via callback.
///
/// Protocol: Content-Length framed JSON-RPC 2.0 (same as relay ↔ CLI).
/// WS methods: discord.register, discord.unregister, discord.send, discord.channels, discord.guilds
@MainActor
final class DiscordService: ObservableObject {

    struct ChannelBinding: Codable, Identifiable {
        var id: String { channelId }
        let channelId: String
        let projectId: String
        var channelName: String?
        var guildName: String?
    }

    struct DiscordMessage {
        let channelId: String
        let channelName: String?
        let guildName: String?
        let senderId: String
        let senderName: String
        let text: String
        let projectId: String
        let timestamp: Int?
    }

    // MARK: - Published State

    @Published var isConnected = false
    @Published var registeredChannels: [ChannelBinding] = []

    // MARK: - Callbacks

    var onIncomingMessage: ((DiscordMessage) -> Void)?

    // MARK: - Config

    private var relayHost: String
    private var relayPort: UInt16
    private let workspaceURL: URL

    // MARK: - WebSocket

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var rpcId = 0

    // MARK: - Persistence

    private var bindingsURL: URL {
        workspaceURL.appendingPathComponent(".neo/discord-bindings.json")
    }

    // MARK: - Init

    init(workspaceURL: URL, relayHost: String, relayPort: UInt16) {
        self.workspaceURL = workspaceURL
        self.relayHost = relayHost
        self.relayPort = relayPort
        loadBindings()
    }

    // MARK: - Lifecycle

    func connect() async {
        guard webSocketTask == nil else { return }

        let scheme = relayPort == 443 ? "wss" : "ws"
        let urlStr = relayPort == 443 ? "\(scheme)://\(relayHost)" : "\(scheme)://\(relayHost):\(relayPort)"
        guard let url = URL(string: urlStr) else {
            NSLog("[Discord] Invalid relay URL: %@", urlStr)
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let sess = URLSession(configuration: config)
        self.session = sess

        let task = sess.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // Wait for handshake
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
        } catch {
            NSLog("[Discord] WebSocket handshake failed: %@", error.localizedDescription)
            disconnect()
            return
        }

        isConnected = true
        NSLog("[Discord] Connected to relay at %@", urlStr)

        // Start receive loop
        receiveTask = Task { await readLoop() }

        // Start keepalive
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                self.webSocketTask?.sendPing { _ in }
            }
        }

        // Send ping to relay
        _ = try? await sendRPC(method: "ping", params: nil)

        // Re-register all persisted bindings
        for binding in registeredChannels {
            let result = try? await sendRPC(
                method: "discord.register",
                params: ["channelId": binding.channelId, "projectId": binding.projectId]
            )
            if let result, result.ok {
                NSLog("[Discord] Re-registered #%@ → %@", binding.channelName ?? binding.channelId, binding.projectId)
            }
        }
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        NSLog("[Discord] Disconnected")
    }

    // MARK: - Channel Management

    func registerChannel(channelId: String, projectId: String) async throws -> ChannelBinding {
        let result = try await sendRPC(
            method: "discord.register",
            params: ["channelId": channelId, "projectId": projectId]
        )

        guard result.ok else {
            throw DiscordError.registrationFailed(result.error ?? "Unknown error")
        }

        var binding = ChannelBinding(channelId: channelId, projectId: projectId)
        binding.channelName = result.channelName
        binding.guildName = result.guildName

        // Update or add
        if let idx = registeredChannels.firstIndex(where: { $0.channelId == channelId }) {
            registeredChannels[idx] = binding
        } else {
            registeredChannels.append(binding)
        }
        saveBindings()

        NSLog("[Discord] Registered #%@ → project '%@'", binding.channelName ?? channelId, projectId)
        return binding
    }

    func unregisterChannel(channelId: String) async throws {
        _ = try await sendRPC(method: "discord.unregister", params: ["channelId": channelId])
        registeredChannels.removeAll { $0.channelId == channelId }
        saveBindings()
        NSLog("[Discord] Unregistered channel %@", channelId)
    }

    func sendMessage(channelId: String, text: String) async throws {
        let result = try await sendRPC(
            method: "discord.send",
            params: ["channelId": channelId, "text": text]
        )
        guard result.ok else {
            throw DiscordError.sendFailed(result.error ?? "Send failed")
        }
    }

    /// Find which project a channel is bound to.
    func projectForChannel(_ channelId: String) -> String? {
        registeredChannels.first { $0.channelId == channelId }?.projectId
    }

    // MARK: - Guild/Channel Discovery

    struct GuildInfo: Identifiable {
        var id: String { guildId }
        let guildId: String
        let guildName: String
        var channels: [ChannelInfo]
    }

    struct ChannelInfo: Identifiable {
        var id: String { channelId }
        let channelId: String
        let channelName: String
        let type: Int // 0 = text, 2 = voice, 4 = category
    }

    func fetchGuilds() async throws -> [GuildInfo] {
        guard let task = webSocketTask else { throw DiscordError.notConnected }

        rpcId += 1
        let id = rpcId
        let jsonStr = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"discord.guilds\",\"params\":{}}"
        let jsonData = Data(jsonStr.utf8)
        let header = "Content-Length: \(jsonData.count)\r\n\r\n"
        var framed = Data(header.utf8)
        framed.append(jsonData)
        try await task.send(.data(framed))

        // Wait for raw JSON response
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            if let raw = pendingRawResponses[id] {
                pendingRawResponses.removeValue(forKey: id)
                return parseGuilds(from: raw)
            }
        }
        throw DiscordError.timeout
    }

    private var pendingRawResponses: [Int: [String: Any]] = [:]

    private func parseGuilds(from json: [String: Any]) -> [GuildInfo] {
        guard let result = json["result"] as? [String: Any],
              let guildsArr = result["guilds"] as? [[String: Any]] else { return [] }
        return guildsArr.compactMap { g in
            guard let gid = g["guildId"] as? String,
                  let name = g["guildName"] as? String,
                  let channels = g["channels"] as? [[String: Any]] else { return nil }
            let chInfos = channels.compactMap { c -> ChannelInfo? in
                guard let cid = c["id"] as? String,
                      let cname = c["name"] as? String,
                      let ctype = c["type"] as? Int else { return nil }
                return ChannelInfo(channelId: cid, channelName: cname, type: ctype)
            }
            return GuildInfo(guildId: gid, guildName: name, channels: chInfos)
        }
    }

    // MARK: - WebSocket I/O

    /// Simple JSON-RPC response value for Discord bridge operations.
    struct RPCResult: Sendable {
        var ok: Bool = false
        var error: String?
        var channelName: String?
        var guildName: String?
        var raw: [String: String] = [:]
    }

    private func sendRPC(method: String, params: [String: String]?) async throws -> RPCResult {
        guard let task = webSocketTask else { throw DiscordError.notConnected }

        rpcId += 1
        // Build request JSON manually to avoid Any
        var parts = ["\"jsonrpc\":\"2.0\"", "\"id\":\(rpcId)", "\"method\":\"\(method)\""]
        if let params {
            let paramParts = params.map { "\"\($0.key)\":\"\($0.value)\"" }
            parts.append("\"params\":{\(paramParts.joined(separator: ","))}")
        }
        let jsonStr = "{\(parts.joined(separator: ","))}"
        let jsonData = Data(jsonStr.utf8)
        let header = "Content-Length: \(jsonData.count)\r\n\r\n"
        var framed = Data(header.utf8)
        framed.append(jsonData)

        try await task.send(.data(framed))

        // Wait for response with matching id (with timeout)
        let expectedId = rpcId
        for _ in 0..<300 { // 30 second timeout (100ms intervals)
            try await Task.sleep(for: .milliseconds(100))
            if let response = pendingResponses[expectedId] {
                pendingResponses.removeValue(forKey: expectedId)
                return response
            }
        }
        throw DiscordError.timeout
    }

    // Pending RPC responses (filled by readLoop)
    private var pendingResponses: [Int: RPCResult] = [:]

    private nonisolated func readLoop() async {
        var buffer = Data()

        while true {
            guard let task = await self.webSocketTask else { break }
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data): buffer.append(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) { buffer.append(data) }
                @unknown default: break
                }

                // Extract Content-Length framed messages
                while let (msgData, consumed) = Self.extractFrame(from: buffer) {
                    buffer = Data(buffer.dropFirst(consumed))
                    await handleIncoming(msgData)
                }
            } catch {
                NSLog("[Discord] WebSocket receive error: %@", error.localizedDescription)
                await MainActor.run { [weak self] in self?.isConnected = false }
                break
            }
        }
    }

    private static nonisolated func extractFrame(from buffer: Data) -> (Data, Int)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let headerStr = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        guard let colonRange = headerStr.range(of: ":", options: .literal),
              let length = Int(headerStr[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let bodyStart = headerEnd.upperBound
        let totalLength = buffer.distance(from: buffer.startIndex, to: bodyStart) + length
        guard buffer.count >= totalLength else { return nil }
        let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)]
        return (Data(body), totalLength)
    }

    private func handleIncoming(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // RPC response (has "id" and "result"/"error")
        if let id = json["id"] as? Int {
            // Store raw response for complex queries (fetchGuilds)
            pendingRawResponses[id] = json

            var result = RPCResult()
            if let resultObj = json["result"] as? [String: Any] {
                result.ok = resultObj["ok"] as? Bool ?? true
                result.channelName = resultObj["channelName"] as? String
                result.guildName = resultObj["guildName"] as? String
                result.error = resultObj["error"] as? String
            } else if let errorObj = json["error"] as? [String: Any] {
                result.ok = false
                result.error = errorObj["message"] as? String ?? "RPC error"
            } else {
                result.ok = true
            }
            pendingResponses[id] = result
            return
        }

        // Notification (has "method" but no "id")
        if let method = json["method"] as? String, method == "discord_message",
           let params = json["params"] as? [String: Any] {
            let msg = DiscordMessage(
                channelId: params["channelId"] as? String ?? "",
                channelName: params["channelName"] as? String,
                guildName: params["guildName"] as? String,
                senderId: params["senderId"] as? String ?? "",
                senderName: params["senderName"] as? String ?? "Unknown",
                text: params["text"] as? String ?? "",
                projectId: params["projectId"] as? String ?? "",
                timestamp: params["timestamp"] as? Int
            )
            NSLog("[Discord] Message from %@ in #%@: %@", msg.senderName, msg.channelName ?? msg.channelId, String(msg.text.prefix(60)))
            onIncomingMessage?(msg)
        }
    }

    // MARK: - Persistence

    private func loadBindings() {
        guard let data = try? Data(contentsOf: bindingsURL),
              let bindings = try? JSONDecoder().decode([ChannelBinding].self, from: data) else { return }
        registeredChannels = bindings
        NSLog("[Discord] Loaded %d channel bindings", bindings.count)
    }

    private func saveBindings() {
        let dir = bindingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(registeredChannels) {
            try? data.write(to: bindingsURL)
        }
    }

    // MARK: - Errors

    enum DiscordError: LocalizedError {
        case notConnected
        case registrationFailed(String)
        case sendFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to relay"
            case .registrationFailed(let msg): return "Registration failed: \(msg)"
            case .sendFailed(let msg): return "Send failed: \(msg)"
            case .timeout: return "Request timed out"
            }
        }
    }
}
