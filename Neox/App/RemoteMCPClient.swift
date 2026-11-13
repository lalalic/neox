import Foundation
import Security
import SwiftUI
import CryptoKit
import Network

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
    @Published private(set) var selectedMasterName = UserDefaults.standard.string(forKey: "neox.selectedMasterName") ?? "Neo Master"
    @Published var endpoint = UserDefaults.standard.string(forKey: "remoteMCPURL") ?? ""
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    @Published var terminalOutput = ""

    private var terminalTool = ""
    private var sessionID: String?
    private var sessionGeneration = 0
    private var cursor = 0
    private var terminalPollInFlight = false
    private var requestID = 0
    private let legacyCredentialKey = "com.neox.app.remote-mcp-token"
    private let savedMacsKey = "remoteMCPHistoryV1"
    private let namedMastersKey = "neox.knownMastersV1"
    private var bearer = ""
    private var localEndpoint: String?
    private var activeEndpoint: String?
    private var remoteToolNames: [String] = []

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
    var hasConfiguredAddress: Bool { !endpoint.isEmpty }
    var usingLAN: Bool { activeEndpoint?.hasPrefix("http://") == true }

    func preferPublicForDesktop() {
        activeEndpoint = endpoint
    }

    /// Keep the saved HTTPS identity; a local address is only a transport hint.
    func useLocalEndpoint(ip: String?, port: UInt16?) {
        guard let ip, let port, IPv4Address(ip) != nil,
              ip != "127.0.0.1" else {
            localEndpoint = nil
            return
        }
        localEndpoint = "http://\(ip):\(port)/mcp"
    }

    /// The Bonjour-selected Mac is the only authority for Remote Mac selection.
    /// Never send an existing access code to a newly advertised URL: Bonjour
    /// announcements are unauthenticated and must not authorize secret transfer.
    func selectMaster(name: String, advertisedURL: String?) {
        guard !name.isEmpty else { return }
        var known = UserDefaults.standard.dictionary(forKey: namedMastersKey) as? [String: String] ?? [:]
        let firstBinding = selectedMasterName == "Neo Master" && known.isEmpty
        if firstBinding, !endpoint.isEmpty { known[name] = endpoint }
        selectedMasterName = name
        UserDefaults.standard.set(name, forKey: "neox.selectedMasterName")
        let advertised = advertisedURL.flatMap(Self.validEndpoint)
        let target = advertised ?? known[name] ?? (firstBinding ? endpoint : "")
        guard !target.isEmpty else {
            endpoint = ""
            bearer = ""
            connected = false
            return
        }
        if target != endpoint {
            endpoint = target
            activeEndpoint = nil
            bearer = Self.readSecret(account: Self.credentialAccount(for: target)) ?? ""
            connected = false
        }
        known[name] = target
        UserDefaults.standard.set(known, forKey: namedMastersKey)
        UserDefaults.standard.set(target, forKey: "remoteMCPURL")
    }

    private static func validEndpoint(_ raw: String) -> String? {
        guard let url = URL(string: raw), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.hasSuffix("/mcp") ? value : value + "/mcp"
    }
    var isTerminalActive: Bool { sessionID != nil }
    var hasTerminalTool: Bool { !terminalTool.isEmpty }

    func openVNCTunnel() async throws -> VNCLoopbackRelay {
        guard connected, !bearer.isEmpty else { throw RemoteError.missingCredential }
        let isLAN = activeEndpoint?.hasPrefix("http://") == true
        return try await VNCLoopbackRelay.start(url: remoteURL(path: "/vnc", scheme: isLAN ? "ws" : "wss"), token: bearer)
    }

    /// Feature routes share the configured Neo Remote host and HTTPS gateway.
    /// Use WSS only for streaming endpoints such as VNC.
    func remoteURL(path: String, scheme: String = "https") throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("?"), !path.contains("#"),
              let source = URL(string: activeEndpoint ?? endpoint),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        else { throw RemoteError.invalidEndpoint }
        components.scheme = scheme
        components.path = path
        components.query = nil
        guard let result = components.url else { throw RemoteError.invalidEndpoint }
        return result
    }

    func saveConfiguration(url: String, token: String) throws {
        guard let normalized = Self.validEndpoint(url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RemoteError.invalidEndpoint
        }
        if !token.isEmpty {
            try Self.saveSecret(token, account: Self.credentialAccount(for: normalized))
            bearer = token
        } else if normalized != endpoint {
            bearer = Self.readSecret(account: Self.credentialAccount(for: normalized)) ?? ""
        }
        guard !bearer.isEmpty else { throw RemoteError.missingCredential }
        endpoint = normalized
        activeEndpoint = nil
        UserDefaults.standard.set(normalized, forKey: "remoteMCPURL")
        var known = UserDefaults.standard.dictionary(forKey: namedMastersKey) as? [String: String] ?? [:]
        known[selectedMasterName] = normalized
        UserDefaults.standard.set(known, forKey: namedMastersKey)
        connected = false
    }

    func useSavedMac(_ mac: SavedMac) {
        endpoint = mac.url
        activeEndpoint = nil
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
        MacScreenCredentials.delete(for: endpoint)
        Self.deleteSecret(account: Self.credentialAccount(for: endpoint))
        savedMacs.removeAll { $0.url == endpoint }
        UserDefaults.standard.set(savedMacs.map(\.url), forKey: savedMacsKey)
        var known = UserDefaults.standard.dictionary(forKey: namedMastersKey) as? [String: String] ?? [:]
        known.removeValue(forKey: selectedMasterName)
        UserDefaults.standard.set(known, forKey: namedMastersKey)
        endpoint = ""
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
            remoteToolNames = names
            // Federated Core tools keep their provider-defined names.
            terminalTool = names.first { $0 == "terminal" || $0.hasSuffix(".terminal") || $0 == "neo_terminal" } ?? ""
            connected = true
            rememberCurrentMac()
            // Device registration is part of connecting to a verified Master.
            // APNs credentials may arrive later and update this same record.
            Task { [weak self] in try? await self?.registerDevice() }
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
        guard let sessionID, !terminalPollInFlight else { return }
        terminalPollInFlight = true
        defer { terminalPollInFlight = false }
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

    private var chatGatewayProvider: String {
        #if DEBUG
        // Test builds may explicitly opt in to an isolated staging provider.
        // Production builds always use the canonical federated MCP.
        if ProcessInfo.processInfo.arguments.contains("-neo-chat-staging") {
            return "mcp.chat-gateway-staging"
        }
        #endif
        return "mcp.chat-gateway"
    }

    /// The Chat tab uses the existing saved authenticated HTTPS Master, never a
    /// second listener or credentials copied from a Bonjour discovery result.
    func relayJobs(offset: Int = 0, limit: Int = RelayJobsPage.pageSize) async throws -> RelayJobsPage {
        let result = try await callAuthenticatedTool(chatGatewayProvider, [
            "command": "chat_jobs", "args": ["limit": limit, "offset": offset]
        ])
        guard let rows = result["jobs"] as? [[String: Any]],
              let total = result["total"] as? Int, total >= 0,
              let nextOffset = result["nextOffset"] as? Int,
              nextOffset >= 0, nextOffset <= total,
              let hasMore = result["hasMore"] as? Bool,
              hasMore == (nextOffset < total),
              (nextOffset >= offset || !hasMore),
              rows.count <= limit else {
            throw RemoteError.invalidResponse
        }
        return RelayJobsPage(jobs: rows.compactMap { RelayJob(wire: $0) },
                             total: total, nextOffset: nextOffset, hasMore: hasMore)
    }

    /// Read only allowlisted activity from the authenticated Master. Source
    /// events have no client ID; attach a stable position-based UI identity.
    func relayJobActivity(_ job: RelayJob) async throws -> [RelayJobActivityEvent] {
        let result = try await callAuthenticatedTool(chatGatewayProvider, [
            "command": "chat_job_activity",
            "args": ["repository": job.repository, "jobId": job.id]
        ])
        guard result["repository"] as? String == job.repository,
              result["jobId"] as? String == job.id,
              result["source"] as? String == "events-bus-history",
              let rows = result["events"] as? [[String: Any]] else {
            throw RemoteError.invalidResponse
        }
        return rows.enumerated().compactMap { index, row in
            RelayJobActivityEvent(wire: row, fallbackID: "\(job.id)-\(index)")
        }
    }

    /// Relay's Graph-owned cancellation must reach durable CANCELLED before
    /// this method returns a success; a request acknowledgement is insufficient.
    func cancelRelayJob(_ job: RelayJob) async throws -> RelayJob {
        guard job.canCancel else { throw RelayJobCancellationError.unsupported }
        let result = try await callAuthenticatedTool(chatGatewayProvider, [
            "command": "chat_job_cancel",
            "args": ["repository": job.repository, "jobId": job.id]
        ])
        guard result["status"] as? String == "cancelled",
              result["repository"] as? String == job.repository,
              result["id"] as? String == job.id else {
            throw RelayJobCancellationError.unconfirmed
        }
        var receipt = result
        receipt["status"] = "CANCELLED"
        guard let confirmed = RelayJob(wire: receipt), confirmed.lifecycle == .cancelled else {
            throw RelayJobCancellationError.unconfirmed
        }
        return confirmed
    }

    func chatGatewayFeed() async throws -> [ChatGatewayItem] {
        let result = try await callAuthenticatedTool(chatGatewayProvider, [
            "command": "chat_feed", "args": ["limit": 100]
        ])
        guard let items = result["items"] as? [[String: Any]] else {
            throw RemoteError.invalidResponse
        }
        return try items.map { try ChatGatewayItem(wire: $0) }
    }

    func chatGatewayHeadBound() async throws -> Bool {
        let result = try await callAuthenticatedTool(chatGatewayProvider, [
            "command": "chat_head", "args": [:]
        ])
        guard let bound = result["bound"] as? Bool else { throw RemoteError.invalidResponse }
        return bound
    }

    /// Queued submission is not a ChatGPT response. The orchestrator reports
    /// replies explicitly through chat_report, which the Chat tab then fetches.
    func sendChatGatewayMessage(_ text: String, requestID: String,
                                attachments: [ChatLocalAttachment] = []) async throws {
        let chunkSize = 128 * 1024
        for attachment in attachments {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: attachment.path))
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard bytes.count == attachment.size, digest == attachment.sha256,
                  bytes.count > 0, bytes.count <= 12 * 1024 * 1024 else {
                throw RemoteError.toolFailure("Local attachment changed before sending")
            }
            let chunks = (bytes.count + chunkSize - 1) / chunkSize
            for index in 0..<chunks {
                let start = index * chunkSize
                let end = min(bytes.count, start + chunkSize)
                let receipt = try await callAuthenticatedTool(chatGatewayProvider, [
                    "command": "chat_upload",
                    "args": [
                        "requestId": requestID,
                        "attachmentId": attachment.id,
                        "name": attachment.name,
                        "chunkIndex": index,
                        "chunkCount": chunks,
                        "contentBase64": Data(bytes[start..<end]).base64EncodedString(),
                        "size": attachment.size,
                        "sha256": attachment.sha256,
                    ]
                ])
                guard receipt["attachmentId"] as? String == attachment.id else {
                    throw RemoteError.invalidResponse
                }
                if index == chunks - 1 && receipt["complete"] as? Bool != true {
                    throw RemoteError.invalidResponse
                }
            }
        }
        let refs: [[String: String]] = attachments.map { ["id": $0.id, "name": $0.name] }
        let receipt = try await callAuthenticatedTool(chatGatewayProvider, [
            "command": "chat_send",
            "args": ["text": text, "requestId": requestID, "attachments": refs]
        ])
        guard receipt["status"] as? String == "submitted",
              receipt["id"] as? String == requestID else {
            throw RemoteError.toolFailure("Neo Master did not confirm queued message submission")
        }
    }

    /// One generic device registration after the Master Access Code is verified.
    /// A refreshed APNs token updates the same device record.
    func registerDevice(deviceID: String? = nil, token: String? = nil,
                        environment: String? = nil) async throws {
        // Status/connect probes run frequently. Do not rewrite the device store
        // every 30 seconds; a token refresh always bypasses this throttle.
        let cacheKey = "neox.deviceRegistration." + Self.credentialAccount(for: endpoint)
        if token == nil && Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: cacheKey) < 3600 {
            return
        }
        var device: [String: Any] = ["deviceId": deviceID ?? Self.persistentDeviceID()]
        if let token, let environment {
            device["token"] = token
            device["environment"] = environment
        }
        let result = try await mobileDeviceREST(body: device)
        guard result["registered"] as? Bool == true else {
            throw RemoteError.toolFailure("Neo Master did not acknowledge device registration")
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheKey)
    }

    /// The wrapper is the delivery queue. Only the phone stores review history.
    func acquireMarkcutReviews(requestID: String? = nil, ackIDs: [String] = []) async throws -> [MarkcutReviewRequest] {
        var arguments: [String: Any] = ["deviceId": Self.persistentDeviceID(), "ackIds": ackIDs]
        if let requestID { arguments["requestId"] = requestID }
        let result = try await callAuthenticatedTool("review.preview.acquire", arguments)
        guard let items = result["requests"] as? [[String: Any]] else {
            throw RemoteError.toolFailure("Preview acquisition did not return a request list")
        }
        return try items.enumerated().map { index, dictionary in
            do {
                let bytes = try JSONSerialization.data(withJSONObject: dictionary)
                return try JSONDecoder().decode(MarkcutReviewRequest.self, from: bytes)
            } catch {
                throw RemoteError.toolFailure("Preview request \(index + 1) cannot be decoded: \(error.localizedDescription)")
            }
        }
    }

    private static func persistentDeviceID() -> String {
        let key = "neox.masterDeviceId"
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil {
            return saved.lowercased()
        }
        let value = (UIDevice.current.identifierForVendor ?? UUID()).uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    func acknowledgeAcquiredReviews(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let result = try await callAuthenticatedTool("review.preview.acquire", [
            "deviceId": Self.persistentDeviceID(), "ackIds": ids
        ])
        guard let acked = result["acked"] as? [String], Set(acked) == Set(ids) else {
            throw RemoteError.toolFailure("Neo Master did not acknowledge acquired reviews")
        }
    }

    /// Review media and feedback always use the saved Master's authenticated
    /// HTTPS gateway. The request list itself is owned and stored by this phone.
    func markcutPreviewMedia(contentHash: String) async throws -> [String: Any] {
        let media = try await callAuthenticatedTool("markcut.preview.media", ["contentHash": contentHash])
        // Load executable video-player JS only from the already trusted Master.
        guard let player = media["playerUrl"] as? String,
              let url = URL(string: player), let gateway = URL(string: endpoint),
              url.scheme == "https", url.host == gateway.host,
              url.path.hasPrefix("/files/_neoy/markcut/") else {
            throw RemoteError.toolFailure("Master returned an untrusted Markcut player URL")
        }
        return media
    }

    func deliverMarkcutReviewFeedback(request: MarkcutReviewRequest,
                                      feedback: MarkcutReviewFeedback) async throws {
        if request.effectiveDelivery == "event" {
            guard let template = request.eventTemplate else { throw RemoteError.toolsUnavailable }
            let event = try template.event(review: feedback.reviewResult(request: request))
            let receipt = try await callAuthenticatedTool("events", [
                "command": "publish", "args": event
            ])
            guard receipt["published"] as? Bool == true else {
                throw RemoteError.toolFailure("Events MCP did not acknowledge publish")
            }
            return
        }
        // Explicit text reviews use the Agent new-turn route. Legacy callback
        // requests retain their old behavior until their outstanding queue drains.
        let tool = request.delivery == "text" ? "chatgpt" : (request.ownerCallbackTool ?? "")
        guard !tool.isEmpty else { throw RemoteError.toolsUnavailable }
        if tool == "chatgpt" {
            guard let threadID = request.ownerThreadID else { throw RemoteError.toolsUnavailable }
            let message = MarkcutReviewFeedback.chatGPTMessage(request: request, feedback: feedback)
            let receipt = try await callAuthenticatedTool("chatgpt", [
                "command": "turn", "args": ["thread_id": threadID, "message": message,
                                            "mode": "async", "mergeable": false,
                                            "reason": "Neo Mobile video review feedback"]
            ])
            try MarkcutReviewFeedback.requireChatGPTReceipt(receipt)
            return
        }
        let result = try await callAuthenticatedTool(tool, [
            "requestId": request.id,
            "revisionId": request.revisionID,
            "contentHash": request.contentHash,
            "decision": feedback.decision.rawValue,
            "feedback": feedback.feedback,
            "idempotencyKey": feedback.idempotencyKey
        ])
        try MarkcutReviewFeedback.requireAcknowledgement(result)
    }

    /// Generic device registration is protected by the existing Master Access Code.
    private func mobileDeviceREST(body: [String: Any]) async throws -> [String: Any] {
        guard let source = URL(string: endpoint), source.scheme == "https", !bearer.isEmpty,
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            throw RemoteError.missingCredential
        }
        components.path = "/mobile/device/register"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw RemoteError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteError.invalidResponse
        }
        return result
    }

    // These two app-internal tools retain direct MCP names at the Neo gateway.
    // Do not depend on model-visible discovery for app-only capabilities.
    private static let directAppOnlyToolNames: Set<String> = ["review.preview.acquire", "markcut.preview.media"]

    static func resolvedToolName(_ requested: String, advertised: [String]) -> String? {
        if directAppOnlyToolNames.contains(requested) { return requested }
        return advertised.first { $0 == requested || $0.hasSuffix("." + requested) }
    }

    private func callAuthenticatedTool(_ toolName: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        // Resolve the requested provider tool on the saved HTTPS endpoint; never
        // redirect credentials to an endpoint carried by a review request.
        guard URL(string: endpoint)?.scheme == "https", !bearer.isEmpty else { throw RemoteError.missingCredential }
        // App-only MCP tools are deliberately absent from generic tools/list.
        // The app knows their exact, Neo-owned names; routing through discovery
        // makes review acquisition and media playback fail with toolsUnavailable.
        if !Self.directAppOnlyToolNames.contains(toolName) && remoteToolNames.isEmpty {
            let listing = try await requestRPC(method: "tools/list", params: [:], address: endpoint)
            remoteToolNames = (listing["tools"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
        }
        guard let name = Self.resolvedToolName(toolName, advertised: remoteToolNames) else {
            throw RemoteError.toolsUnavailable
        }
        let response = try await requestRPC(method: "tools/call", params: ["name":name,"arguments":arguments], address:endpoint)
        let blocks = response["content"] as? [[String: Any]] ?? []
        if response["isError"] as? Bool == true {
            throw RemoteError.toolFailure(blocks.compactMap { $0["text"] as? String }.joined(separator:"\n"))
        }
        if let structured = response["structuredContent"] as? [String: Any] { return structured }
        if let text = blocks.compactMap({ $0["text"] as? String }).first,
           let data = text.data(using:.utf8),
           let dictionary = try? JSONSerialization.jsonObject(with:data) as? [String:Any] { return dictionary }
        return response
    }

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        if let activeEndpoint {
            do {
                return try await requestRPC(method: method, params: params, address: activeEndpoint)
            } catch {
                guard activeEndpoint != endpoint else { throw error }
                self.activeEndpoint = endpoint
                return try await requestRPC(method: method, params: params, address: endpoint)
            }
        }
        if let localEndpoint {
            do {
                let response = try await requestRPC(method: method, params: params, address: localEndpoint)
                activeEndpoint = localEndpoint
                return response
            } catch {
                // LAN unavailable or rejects this credential: use the existing gateway.
            }
        }
        let response = try await requestRPC(method: method, params: params, address: endpoint)
        activeEndpoint = endpoint
        return response
    }

    private func requestRPC(method: String, params: [String: Any], address: String) async throws -> [String: Any] {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""),
              !bearer.isEmpty else {
            throw RemoteError.invalidEndpoint
        }
        requestID += 1
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = address == localEndpoint && activeEndpoint == nil ? 2 : 20
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
