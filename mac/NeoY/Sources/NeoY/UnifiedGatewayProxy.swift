import Foundation
import Network
import Security
import CryptoKit

/// Neo Core is the sole authenticated HTTPS edge for these loopback services.
/// This component only authorizes methods/paths and streams bytes. It does not
/// implement Relay jobs or Orchestrator business logic.
enum UnifiedGatewayRoute {
    struct Target: Equatable {
        let port: Int
        let path: String
        let requiresModelToken: Bool
        let streaming: Bool
    }

    static let dashboardAssets: Set<String> = [
        "", "index.html", "dashboard.css", "dashboard.js", "dashboard-config.js",
        "pwa.js", "service-worker.js", "manifest.webmanifest",
        "vendor/markdown-it.min.js", "icons/icon-180.png",
        "icons/icon-192.png", "icons/icon-512.png"
    ]
    private static let relayReads: Set<String> = [
        "version", "jobs", "job", "events", "runtime-summary", "status", "usage",
        "graphs", "graph-symbol", "decision-audit", "execution-router-rules",
        "troubleshooter-qa"
    ]
    private static let relayWrites: [String: Set<String>] = [
        "job-action": ["POST"], "task-action": ["POST"],
        "job-state": ["POST"], "task-state": ["POST"],
        "control": ["POST"], "task-command": ["POST"],
        "router-test": ["POST"], "execution-router-rules": ["PUT"],
        "troubleshooter-qa": ["PUT"]
    ]
    private static let mobileReads: Set<String> = ["mobile/jobs", "mobile/job-tasks", "mobile/job-activity", "mobile/events"]
    private static let orchestratorMethods: [String: String] = [
        "messages": "POST", "events": "GET", "pending": "GET",
        "ack": "POST", "attachments": "POST", "health": "GET"
    ]

    /// An unauthenticated HTML navigation must show the sign-in page instead
    /// of returning a blank 401 body. Never redirect API, assets or Bearer callers.
    static func needsDashboardLogin(method: String, path: String,
                                    browserAuthorized: Bool, bearerAuthorized: Bool) -> Bool {
        method == "GET" && !browserAuthorized && !bearerAuthorized &&
            (path == "/dashboard/" || path == "/dashboard/index.html")
    }

    static func match(method: String, path: String, browserAuthorized: Bool, bearerAuthorized: Bool) -> Target? {
        guard !path.contains("%"), !path.contains(".."), !path.contains("//"),
              method == method.uppercased() else { return nil }
        if path.hasPrefix("/dashboard/") {
            guard browserAuthorized, method == "GET" else { return nil }
            let asset = String(path.dropFirst("/dashboard/".count))
            guard dashboardAssets.contains(asset) else { return nil }
            return Target(port: 8787, path: asset.isEmpty ? "/" : "/" + asset,
                          requiresModelToken: false, streaming: false)
        }
        if path == "/relay/events" {
            guard browserAuthorized, method == "GET" else { return nil }
            return Target(port: 8787, path: "/events", requiresModelToken: false, streaming: true)
        }
        if path.hasPrefix("/relay/api/") {
            let name=String(path.dropFirst("/relay/api/".count))
            if browserAuthorized && (method == "GET" && relayReads.contains(name)
                || relayWrites[name]?.contains(method) == true) {
                return Target(port: 8787, path: "/api/" + name, requiresModelToken: false, streaming: false)
            }
            if bearerAuthorized && (method == "GET" && mobileReads.contains(name)
                || method == "POST" && name == "mobile/job-cancel") {
                return Target(port: 8787, path: "/api/" + name, requiresModelToken: false,
                              streaming: name == "mobile/events")
            }
            return nil
        }
        if bearerAuthorized && path.hasPrefix("/orchestrator-chat/") {
            let name=String(path.dropFirst("/orchestrator-chat/".count))
            guard orchestratorMethods[name] == method else { return nil }
            return Target(port: 8769, path: path, requiresModelToken: true, streaming: name == "events")
        }
        return nil
    }
}

/// Cookie authentication is never inferred from an MCP token in the URL.
/// Secure, HttpOnly, SameSite=Strict browser sessions are separate from mobile Bearer auth.
final class UnifiedGatewayBrowserSessions: @unchecked Sendable {
    typealias Principal = NeoYOAuthService.BrowserPrincipal
    private struct Session: Codable { let csrf: String; let principal: Principal }
    private struct Ticket { let principal: Principal; let expires: Date }
    private struct Store: Codable { let epoch: String; let entries: [String: Session] }
    private let lock=NSLock()
    private var entries: [String: Session] = [:]
    private var tickets: [String: Ticket] = [:]
    private var stateURL: URL?
    private var epoch = ""

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func secret() -> String {
        var bytes=[UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // Persist only session digests and CSRF state. Operator rotation invalidates
    // the entire browser store, just like the existing OAuth token epoch.
    func configure(file: URL, operatorCredential: String) {
        lock.lock();defer {lock.unlock()}
        let next = Self.digest(operatorCredential)
        if stateURL == file && epoch == next { return }
        stateURL=file;epoch=next;tickets.removeAll();entries.removeAll()
        if let data=try? Data(contentsOf:file),
           let store=try? JSONDecoder().decode(Store.self,from:data),store.epoch==epoch {
            let now=Date().timeIntervalSince1970
            entries=store.entries.filter { $0.value.principal.expiresAt > now }
        }
    }
    private func persistLocked() -> Bool {
        guard let stateURL else { return true } // isolated unit tests
        do {
            try FileManager.default.createDirectory(at:stateURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            let data=try JSONEncoder().encode(Store(epoch:epoch,entries:entries))
            // Stage a private file before atomic replacement; no cleartext
            // cookie secrets are written, even during the atomic write.
            let tmp=stateURL.deletingLastPathComponent().appendingPathComponent(".browser-sessions-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:tmp) }
            guard FileManager.default.createFile(atPath:tmp.path,contents:data,attributes:[.posixPermissions:0o600]) else{return false}
            if FileManager.default.fileExists(atPath:stateURL.path) {
                _=try FileManager.default.replaceItemAt(stateURL,withItemAt:tmp,options:.usingNewMetadataOnly)
            } else {try FileManager.default.moveItem(at:tmp,to:stateURL)}
            return true
        } catch {return false}
    }
    private func loginLocked(principal: Principal) -> (cookie: String, csrf: String)? {
        let now=Date().timeIntervalSince1970
        guard principal.expiresAt>now else{return nil}
        entries=entries.filter { $0.value.principal.expiresAt>now }
        let token=Self.secret(), csrf=Self.secret(),key=Self.digest(token)
        entries[key]=Session(csrf:csrf,principal:principal)
        guard persistLocked() else{entries.removeValue(forKey:key);return nil}
        let age=max(1,Int(principal.expiresAt-now))
        return ("neo_gateway_session=\(token); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=\(age)",csrf)
    }
    func login(principal: Principal) -> (cookie: String, csrf: String)? {
        lock.lock();defer {lock.unlock()};return loginLocked(principal:principal)
    }
    // Keep the old in-memory unit-test entry point; production always supplies
    // a principal verified by NeoYOAuthService.
    func login() -> (cookie: String, csrf: String) {
        login(principal:Principal(clientID:nil,accessDigest:nil,
            expiresAt:Date().timeIntervalSince1970+8*3600))!
    }
    func ticket(principal:Principal)->String?{
        lock.lock();defer{lock.unlock()}
        let now=Date()
        guard principal.expiresAt>now.timeIntervalSince1970 else{return nil}
        tickets=tickets.filter{$0.value.expires>now}
        guard tickets.count<128 else{return nil}
        let token=Self.secret();tickets[Self.digest(token)]=Ticket(principal:principal,expires:now.addingTimeInterval(60))
        return token
    }
    func redeem(_ ticket:String,validate:(Principal)->Bool)->(cookie:String,csrf:String)?{
        lock.lock();defer{lock.unlock()}
        guard ticket.count<=128,let record=tickets.removeValue(forKey:Self.digest(ticket)),
            record.expires>Date(),validate(record.principal) else{return nil}
        return loginLocked(principal:record.principal)
    }
    private func cookieKey(_ header:String?)->String?{
        guard let token=header?.split(separator:";").map({$0.trimmingCharacters(in:.whitespaces)})
            .first(where:{$0.hasPrefix("neo_gateway_session=")})?.split(separator:"=",maxSplits:1).last,
            token.count<=128 else{return nil}
        return Self.digest(String(token))
    }
    func csrf(cookieHeader:String?,validate:(Principal)->Bool={_ in true})->String?{
        guard let key=cookieKey(cookieHeader) else{return nil}
        lock.lock();defer{lock.unlock()}
        guard let session=entries[key],session.principal.expiresAt>Date().timeIntervalSince1970,
            validate(session.principal) else{
            if entries.removeValue(forKey:key) != nil {_=persistLocked()}
            return nil
        }
        return session.csrf
    }
    func logout(cookieHeader:String?)->Bool{
        guard let key=cookieKey(cookieHeader) else{return true}
        lock.lock();defer{lock.unlock()}
        let old=entries.removeValue(forKey:key)
        guard persistLocked() else{entries[key]=old;return false}
        return true
    }
}

/// Prevent the loopback Models bearer token from following upstream 3xx redirects.
private final class UnifiedGatewayNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Sends each upstream chunk on completion before reading the next one; this
/// provides real backpressure rather than buffer-then-sendHTTP behavior.
enum UnifiedGatewayStream {
    private static func send(_ data: Data, _ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {continuation.resume(throwing: error)}
                else {continuation.resume()}
            })
        }
    }
    private static func packet(_ data: Data) -> Data {
        var output=Data(String(data.count,radix:16).utf8)
        output.append(Data("\r\n".utf8));output.append(data);output.append(Data("\r\n".utf8))
        return output
    }
    private static func header(status: Int, contentType: String?, streaming: Bool) -> Data {
        var lines=["HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))",
                   "Transfer-Encoding: chunked", "Connection: close", "Cache-Control: no-store",
                   "X-Content-Type-Options: nosniff", "X-Frame-Options: DENY"]
        if let contentType {lines.append("Content-Type: \(contentType.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))")}
        if streaming {lines.append("X-Accel-Buffering: no")}
        lines.append("");lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }
    static func forward(connection: NWConnection, method: String, target: UnifiedGatewayRoute.Target,
                        query: String?, contentType: String?, idempotencyKey: String?,
                        body: Data?) async {
        var headersSent=false
        do {
            var components=URLComponents();components.scheme="http";components.host="127.0.0.1"
            components.port=target.port;components.path=target.path
            if let query,!query.isEmpty { components.percentEncodedQuery=query }
            guard let url=components.url else {throw URLError(.badURL)}
            var req=URLRequest(url:url);req.httpMethod=method
            req.setValue("identity", forHTTPHeaderField:"Accept-Encoding")
            if let contentType {req.setValue(contentType, forHTTPHeaderField:"Content-Type")}
            if target.path=="/orchestrator-chat/messages" && method=="POST",
               let idempotencyKey,
               idempotencyKey.range(of:"^[A-Za-z0-9_-]{8,128}$", options:.regularExpression) != nil {
                req.setValue(idempotencyKey,forHTTPHeaderField:"Idempotency-Key")
            }
            if let body {req.httpBody=body}
            if target.requiresModelToken {
                let tokenFile=FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/neo/models/token")
                let attrs=try FileManager.default.attributesOfItem(atPath:tokenFile.path)
                guard ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
                    throw URLError(.userAuthenticationRequired)
                }
                let token=try String(contentsOf:tokenFile,encoding:.utf8)
                    .trimmingCharacters(in:.whitespacesAndNewlines)
                guard token.count>=24 else {throw URLError(.userAuthenticationRequired)}
                req.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
            }
            let config=URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest=target.streaming ? 3600 : 120
            config.timeoutIntervalForResource=target.streaming ? 3600 : 120
            config.httpShouldSetCookies=false
            config.urlCache=nil
            let session=URLSession(configuration:config,delegate:UnifiedGatewayNoRedirect(),delegateQueue:nil)
            defer {session.invalidateAndCancel()}
            let (bytes,response)=try await session.bytes(for:req)
            guard let http=response as? HTTPURLResponse else {throw URLError(.badServerResponse)}
            try await send(header(status:http.statusCode,contentType:http.value(forHTTPHeaderField:"Content-Type"),streaming:target.streaming),connection)
            headersSent=true
            var chunk=Data();chunk.reserveCapacity(8192)
            var tail:UInt8=0
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                let ready=target.streaming && tail==10 && byte==10
                tail=byte
                if ready || chunk.count >= (target.streaming ? 1024 : 16_384) {
                    try await send(packet(chunk),connection)
                    chunk.removeAll(keepingCapacity:true)
                }
            }
            if !chunk.isEmpty {try await send(packet(chunk),connection)}
            try await send(Data("0\r\n\r\n".utf8),connection)
        } catch {
            if !headersSent && !Task.isCancelled {
                try? await send(header(status:502,contentType:"application/json",streaming:false),connection)
                try? await send(packet(Data(#"{"error":"upstream_unavailable"}"#.utf8)),connection)
                try? await send(Data("0\r\n\r\n".utf8),connection)
            }
            // Mid-stream termination is detected by a missing SSE terminal
            // event and recovered via the client's durable event cursor.
        }
        connection.cancel()
    }
}

final class UnifiedGatewayInFlight: @unchecked Sendable {
    static let shared=UnifiedGatewayInFlight()
    private let lock=NSLock()
    private var tasks: [ObjectIdentifier: Task<Void,Never>] = [:]
    func install(_ task: Task<Void,Never>, for connection: NWConnection) {
        lock.lock();defer {lock.unlock()}
        tasks[ObjectIdentifier(connection)]?.cancel()
        tasks[ObjectIdentifier(connection)]=task
    }
    func clear(for connection: NWConnection) {
        lock.lock();defer {lock.unlock()}
        tasks.removeValue(forKey:ObjectIdentifier(connection))
    }
    func cancel(for connection: NWConnection) {
        lock.lock()
        let task=tasks.removeValue(forKey:ObjectIdentifier(connection))
        lock.unlock()
        task?.cancel()
    }
}
