import Foundation
import CopilotSDK

/// Lightweight Discord bridge client.
/// Can operate in two modes:
/// 1. Shared: Uses the main ChatViewModel's WS connection (when main relay hosts Discord)
/// 2. Standalone: Creates its own WS to a specified relay (when main relay differs from Discord relay)
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
    @Published var guildId: String {
        didSet { UserDefaults.standard.set(guildId, forKey: "discord_guild_id") }
    }

    // MARK: - Callbacks

    var onIncomingMessage: ((DiscordMessage) -> Void)?

    // MARK: - RPC Provider

    /// RPC sender — set externally (shared mode) or by standalone client.
    var rpcSender: ((String, [String: JSONValue]) async throws -> JSONValue)?

    // MARK: - Standalone Client

    private var standaloneClient: StandaloneRelayClient?

    // MARK: - Config

    private let workspaceURL: URL

    // MARK: - Persistence

    private var bindingsURL: URL {
        workspaceURL.appendingPathComponent(".neo/discord-bindings.json")
    }

    // MARK: - Init

    init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
        self.guildId = UserDefaults.standard.string(forKey: "discord_guild_id") ?? ""
        loadBindings()
    }

    // MARK: - Standalone Connection

    /// Connect to a relay using a standalone WebSocket (when main relay doesn't host Discord).
    func connectStandalone(host: String, port: UInt16) async {
        let client = StandaloneRelayClient(host: host, port: port)
        let notificationHandler: @Sendable (String, [String: JSONValue]?) -> Void = { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleNotification(method: method, params: params)
            }
        }
        await client.setNotificationHandler(notificationHandler)
        standaloneClient = client

        rpcSender = { [weak client] method, params in
            guard let client else { throw DiscordError.notConnected }
            return try await client.sendRPC(method: method, params: params)
        }

        let connected = await client.connect()
        if connected {
            isConnected = true
            await registerBindings()
        } else {
            NSLog("[Discord] Standalone connection failed")
        }
    }

    func disconnectStandalone() {
        Task {
            await standaloneClient?.disconnect()
        }
        standaloneClient = nil
        rpcSender = nil
        isConnected = false
    }

    // MARK: - Connection via shared WS

    /// Register all persisted bindings on the shared connection.
    /// Call after the main ChatViewModel connects.
    func registerBindings() async {
        for binding in registeredChannels {
            do {
                _ = try await sendRPC(
                    method: "discord.register",
                    params: ["channelId": .string(binding.channelId), "projectId": .string(binding.projectId)]
                )
                NSLog("[Discord] Re-registered #%@ → %@", binding.channelName ?? binding.channelId, binding.projectId)
            } catch {
                NSLog("[Discord] Failed to re-register #%@: %@", binding.channelName ?? binding.channelId, error.localizedDescription)
            }
        }
        isConnected = true
    }

    func markDisconnected() {
        isConnected = false
    }

    // MARK: - Notification Handling

    /// Handle a custom notification from the shared WS (called by ChatViewModel.onCustomNotification).
    func handleNotification(method: String, params: [String: JSONValue]?) {
        guard method == "discord_message", let params else { return }

        let msg = DiscordMessage(
            channelId: params["channelId"]?.stringValue ?? "",
            channelName: params["channelName"]?.stringValue,
            guildName: params["guildName"]?.stringValue,
            senderId: params["senderId"]?.stringValue ?? "",
            senderName: params["senderName"]?.stringValue ?? "Unknown",
            text: params["text"]?.stringValue ?? "",
            projectId: params["projectId"]?.stringValue ?? "",
            timestamp: params["timestamp"]?.intValue
        )
        NSLog("[Discord] Message from %@ in #%@: %@", msg.senderName, msg.channelName ?? msg.channelId, String(msg.text.prefix(60)))
        onIncomingMessage?(msg)
    }

    // MARK: - Channel Management

    func registerChannel(channelId: String, projectId: String) async throws -> ChannelBinding {
        let result = try await sendRPC(
            method: "discord.register",
            params: ["channelId": .string(channelId), "projectId": .string(projectId)]
        )

        guard let resultObj = result.objectValue, resultObj["ok"]?.boolValue == true else {
            let error = result.objectValue?["error"]?.stringValue ?? "Unknown error"
            throw DiscordError.registrationFailed(error)
        }

        var binding = ChannelBinding(channelId: channelId, projectId: projectId)
        binding.channelName = resultObj["channelName"]?.stringValue
        binding.guildName = resultObj["guildName"]?.stringValue

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
        _ = try await sendRPC(method: "discord.unregister", params: ["channelId": .string(channelId)])
        registeredChannels.removeAll { $0.channelId == channelId }
        saveBindings()
        NSLog("[Discord] Unregistered channel %@", channelId)
    }

    func sendMessage(channelId: String, text: String) async throws {
        let result = try await sendRPC(
            method: "discord.send",
            params: ["channelId": .string(channelId), "text": .string(text)]
        )
        guard result.objectValue?["ok"]?.boolValue == true else {
            let error = result.objectValue?["error"]?.stringValue ?? "Send failed"
            throw DiscordError.sendFailed(error)
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
        var params: [String: JSONValue] = [:]
        if !guildId.isEmpty { params["guildId"] = .string(guildId) }
        let result = try await sendRPC(method: "discord.guilds", params: params)
        return parseGuilds(from: result)
    }

    private func parseGuilds(from json: JSONValue) -> [GuildInfo] {
        guard let resultObj = json.objectValue,
              case .array(let guildsArr) = resultObj["guilds"] else { return [] }
        return guildsArr.compactMap { g -> GuildInfo? in
            guard let gObj = g.objectValue,
                  let gid = gObj["guildId"]?.stringValue,
                  let name = gObj["guildName"]?.stringValue,
                  case .array(let channels) = gObj["channels"] else { return nil }
            let chInfos = channels.compactMap { c -> ChannelInfo? in
                guard let cObj = c.objectValue,
                      let cid = cObj["id"]?.stringValue,
                      let cname = cObj["name"]?.stringValue,
                      let ctype = cObj["type"]?.intValue else { return nil }
                return ChannelInfo(channelId: cid, channelName: cname, type: ctype)
            }
            return GuildInfo(guildId: gid, guildName: name, channels: chInfos)
        }
    }

    // MARK: - RPC Helper

    private func sendRPC(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard let sender = rpcSender else { throw DiscordError.notConnected }
        return try await sender(method, params)
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

// MARK: - Standalone Relay Client

/// Minimal WebSocket + Content-Length framed JSON-RPC client for Discord bridge.
/// Used when the main ChatViewModel connects to a different relay than where Discord bot lives.
actor StandaloneRelayClient {
    private let host: String
    private let port: UInt16
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var rpcId = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    var onNotification: (@Sendable (_ method: String, _ params: [String: JSONValue]?) -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func setNotificationHandler(_ handler: @Sendable @escaping (_ method: String, _ params: [String: JSONValue]?) -> Void) {
        onNotification = handler
    }

    func connect() async -> Bool {
        let scheme = port == 443 ? "wss" : "ws"
        let urlStr = port == 443 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
        guard let url = URL(string: urlStr) else { return false }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let sess = URLSession(configuration: config)
        self.session = sess

        let task = sess.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // Verify handshake
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
        } catch {
            NSLog("[Discord-Standalone] Handshake failed: %@", error.localizedDescription)
            disconnect()
            return false
        }

        NSLog("[Discord-Standalone] Connected to %@", urlStr)
        readTask = Task { await readLoop() }
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                self.webSocketTask?.sendPing { _ in }
            }
        }
        // Send initial ping RPC
        _ = try? await sendRPC(method: "ping", params: [:])
        return true
    }

    func disconnect() {
        readTask?.cancel()
        readTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        // Cancel all pending
        for (_, cont) in pending {
            cont.resume(throwing: DiscordService.DiscordError.notConnected)
        }
        pending.removeAll()
    }

    func sendRPC(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard let task = webSocketTask else { throw DiscordService.DiscordError.notConnected }

        rpcId += 1
        let id = rpcId
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let jsonData = try JSONEncoder().encode(request)
        let header = "Content-Length: \(jsonData.count)\r\n\r\n"
        var framed = Data(header.utf8)
        framed.append(jsonData)

        try await task.send(.data(framed))

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    // MARK: - Internal

    private struct JSONRPCRequest: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: [String: JSONValue]
    }

    private func readLoop() async {
        var buffer = Data()
        while let task = webSocketTask {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data): buffer.append(data)
                case .string(let text):
                    if let d = text.data(using: .utf8) { buffer.append(d) }
                @unknown default: break
                }
                while let (msgData, consumed) = extractFrame(from: buffer) {
                    buffer = Data(buffer.dropFirst(consumed))
                    handleIncoming(msgData)
                }
            } catch {
                NSLog("[Discord-Standalone] Read error: %@", error.localizedDescription)
                break
            }
        }
    }

    private func extractFrame(from buffer: Data) -> (Data, Int)? {
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
        guard let json = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return }

        // RPC response
        if case .int(let id) = json["id"] {
            if let cont = pending.removeValue(forKey: id) {
                if let result = json["result"] {
                    cont.resume(returning: result)
                } else if let error = json["error"] {
                    let msg = error.objectValue?["message"]?.stringValue ?? "RPC error"
                    cont.resume(throwing: DiscordService.DiscordError.sendFailed(msg))
                } else {
                    cont.resume(returning: .null)
                }
            }
            return
        }

        // Notification
        if case .string(let method) = json["method"] {
            let params: [String: JSONValue]?
            if case .object(let p) = json["params"] { params = p } else { params = nil }
            onNotification?(method, params)
        }
    }
}
