import Foundation
import CryptoKit
import Security

struct NeoYOAuthHTTPResponse: Sendable {
    let status: Int
    let body: Data?
    let contentType: String
    let headers: [String: String]

    init(status: Int, body: Data? = nil, contentType: String = "application/json", headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.headers = headers
    }
}

/// Minimal OAuth 2.1 authorization server for ChatGPT MCP apps.
///
/// The existing NeoY Core token remains the operator consent secret and a valid
/// Bearer credential for non-ChatGPT clients. OAuth access tokens are issued only
/// after the operator proves possession of that token on /authorize.
final class NeoYOAuthService: @unchecked Sendable {
    private struct PendingAuth {
        let clientID: String
        let redirectURI: String
        let challenge: String
        let state: String?
        let resource: String?
        let issuer: String
        let expiresAt: Date
    }

    private struct PendingCode {
        let clientID: String
        let redirectURI: String
        let challenge: String
        let resource: String?
        let expiresAt: Date
    }

    private struct StoredToken: Codable {
        let digest: String
        let clientID: String
        let audience: String?
        let expiresAt: TimeInterval
    }

    private struct StoreFile: Codable {
        var version: Int = 1
        var clientID: String
        var tokenEpoch: String
        var access: [StoredToken]
        var refresh: [StoredToken]
    }

    private let lock = NSLock()
    private let clientID: String
    private let consentToken: String
    private let tokenEpoch: String
    private let stateURL: URL
    private var pendingAuth: [String: PendingAuth] = [:]
    private var codes: [String: PendingCode] = [:]
    private var access: [String: StoredToken] = [:]
    private var refresh: [String: StoredToken] = [:]

    private let scope = "mcp"
    private let accessTTL: TimeInterval = 3600
    private let refreshTTL: TimeInterval = 30 * 24 * 3600
    private let codeTTL: TimeInterval = 60
    private let authTTL: TimeInterval = 300

    init(clientID: String, consentToken: String, stateURL: URL) {
        self.clientID = clientID
        self.consentToken = consentToken
        self.tokenEpoch = Self.sha256(Self.sha256(consentToken))
        self.stateURL = stateURL
        loadStore()
    }

    func isAuthorizedBearer(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        if Self.constantTimeEqual(token, consentToken) { return true }
        let digest = Self.sha256(token)
        let now = Date().timeIntervalSince1970
        return lock.withLock {
            sweepLocked(now: now)
            return access[digest]?.expiresAt ?? 0 > now
        }
    }

    func challengeHeaders(origin: String) -> [String: String] {
        [
            "WWW-Authenticate": "Bearer resource_metadata=\"\(origin)/.well-known/oauth-protected-resource/mcp\", scope=\"\(scope)\"",
            "Cache-Control": "no-store"
        ]
    }

    func handle(method: String, path: String, requestTarget: String,
                headers: [String: String], body: Data?) -> NeoYOAuthHTTPResponse? {
        guard let origin = publicOrigin(headers: headers) else { return nil }

        let discoveryPaths: Set<String> = [
            "/.well-known/oauth-protected-resource",
            "/.well-known/oauth-protected-resource/mcp",
            "/.well-known/oauth-authorization-server",
            "/.well-known/oauth-authorization-server/mcp",
            "/.well-known/openid-configuration",
            "/.well-known/openid-configuration/mcp",
            "/mcp/.well-known/openid-configuration"
        ]

        if discoveryPaths.contains(path) {
            if method == "OPTIONS" {
                return NeoYOAuthHTTPResponse(status: 204, headers: discoveryHeaders())
            }
            guard method == "GET" || method == "HEAD" else {
                return json(status: 405, ["error": "method_not_allowed"], headers: discoveryHeaders())
            }
            let object: [String: Any]
            if path.contains("oauth-protected-resource") {
                let resource = path.hasSuffix("/mcp") ? origin + "/mcp" : origin
                object = [
                    "resource": resource,
                    "authorization_servers": [origin],
                    "bearer_methods_supported": ["header"],
                    "scopes_supported": [scope]
                ]
            } else {
                object = authorizationServerDocument(origin: origin)
            }
            let response = json(status: 200, object, headers: discoveryHeaders())
            return method == "HEAD" ? NeoYOAuthHTTPResponse(status: 200, headers: discoveryHeaders()) : response
        }

        switch (method, path) {
        case ("GET", "/authorize"):
            return authorizeGET(requestTarget: requestTarget, origin: origin)
        case ("POST", "/authorize"):
            return authorizePOST(body: body, origin: origin)
        case ("POST", "/token"):
            return tokenPOST(body: body, headers: headers)
        case ("POST", "/revoke"):
            return revokePOST(body: body)
        default:
            return nil
        }
    }

    private func authorizationServerDocument(origin: String) -> [String: Any] {
        [
            "issuer": origin,
            "authorization_endpoint": origin + "/authorize",
            "token_endpoint": origin + "/token",
            "revocation_endpoint": origin + "/revoke",
            "revocation_endpoint_auth_methods_supported": ["none"],
            "response_types_supported": ["code"],
            "response_modes_supported": ["query"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "token_endpoint_auth_methods_supported": ["none", "client_secret_post", "client_secret_basic"],
            "code_challenge_methods_supported": ["S256"],
            "scopes_supported": [scope],
            "authorization_response_iss_parameter_supported": true
        ]
    }

    private func authorizeGET(requestTarget: String, origin: String) -> NeoYOAuthHTTPResponse {
        guard let components = URLComponents(string: "http://localhost\(requestTarget)") else {
            return html(status: 400, title: "Authorization failed", body: "Invalid authorization request.")
        }
        let q = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard q["client_id"] == clientID else {
            return html(status: 400, title: "Authorization failed", body: "Unrecognised client_id.")
        }
        guard let redirect = q["redirect_uri"], Self.allowedRedirect(redirect) else {
            return html(status: 400, title: "Authorization failed", body: "Unrecognised redirect_uri.")
        }
        guard q["response_type"] == "code" else {
            return oauthRedirect(redirect, params: errorParams("unsupported_response_type", state: q["state"], issuer: origin))
        }
        guard q["code_challenge_method"] == "S256",
              let challenge = q["code_challenge"], Self.validPKCE(challenge) else {
            return oauthRedirect(redirect, params: errorParams("invalid_request", state: q["state"], issuer: origin))
        }
        if let resource = q["resource"], resource != origin && resource != origin + "/mcp" {
            return oauthRedirect(redirect, params: errorParams("invalid_target", state: q["state"], issuer: origin))
        }

        let rid = Self.randomToken(bytes: 16)
        lock.withLock {
            sweepPendingLocked()
            pendingAuth[rid] = PendingAuth(clientID: clientID, redirectURI: redirect, challenge: challenge,
                                           state: q["state"], resource: q["resource"], issuer: origin,
                                           expiresAt: Date().addingTimeInterval(authTTL))
        }
        let safeRID = Self.htmlEscape(rid)
        let safeIssuer = Self.htmlEscape(origin)
        let safeRedirect = Self.htmlEscape(redirect)
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Authorize NeoY</title><style>body{font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:34rem;margin:3rem auto;padding:0 1.25rem}code{background:#f2f2f2;padding:.1rem .3rem;border-radius:3px;word-break:break-all}input{width:100%;padding:.5rem;box-sizing:border-box}button{margin-top:1rem;padding:.6rem 1.2rem}</style></head><body>
        <h1>Authorize NeoY</h1><p>This grants ChatGPT the NeoY MCP capabilities enabled for remote access.</p>
        <p>Server: <code>\(safeIssuer)</code><br>Redirect: <code>\(safeRedirect)</code></p>
        <form method="post" action="/authorize"><input type="hidden" name="rid" value="\(safeRID)"><label for="token">NeoY token</label><input id="token" type="password" name="token" autocomplete="off"><button type="submit">Approve</button></form>
        </body></html>
        """
        return NeoYOAuthHTTPResponse(status: 200, body: Data(page.utf8), contentType: "text/html; charset=utf-8", headers: [
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https://chatgpt.com; base-uri 'none'; frame-ancestors 'none'",
            "X-Frame-Options": "DENY",
            "Referrer-Policy": "no-referrer"
        ])
    }

    private func authorizePOST(body: Data?, origin: String) -> NeoYOAuthHTTPResponse {
        let form = Self.form(body)
        guard let rid = form["rid"] else {
            return html(status: 400, title: "Authorization failed", body: "Missing request id.")
        }
        guard let pending = lock.withLock({ pendingAuth.removeValue(forKey: rid) }), pending.expiresAt > Date() else {
            return html(status: 400, title: "Authorization failed", body: "This approval link expired. Start again from ChatGPT.")
        }
        guard Self.constantTimeEqual(form["token"] ?? "", consentToken) else {
            return html(status: 403, title: "Authorization failed", body: "The NeoY token did not match. Start again from ChatGPT.")
        }
        let code = Self.randomToken(bytes: 32)
        let codeDigest = Self.sha256(code)
        lock.withLock {
            codes[codeDigest] = PendingCode(clientID: pending.clientID, redirectURI: pending.redirectURI,
                                            challenge: pending.challenge, resource: pending.resource,
                                            expiresAt: Date().addingTimeInterval(codeTTL))
        }
        var params = ["code": code, "iss": pending.issuer]
        if let state = pending.state { params["state"] = state }
        return oauthRedirect(pending.redirectURI, params: params)
    }

    private func tokenPOST(body: Data?, headers: [String: String]) -> NeoYOAuthHTTPResponse {
        var form = Self.form(body)
        if form["client_id"] == nil, let auth = headers["authorization"], auth.lowercased().hasPrefix("basic ") {
            let raw = String(auth.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let data = Data(base64Encoded: raw), let decoded = String(data: data, encoding: .utf8),
               let colon = decoded.firstIndex(of: ":") {
                form["client_id"] = String(decoded[..<colon]).removingPercentEncoding ?? String(decoded[..<colon])
            }
        }
        guard form["client_id"] == clientID else { return oauthError(status: 401, code: "invalid_client", description: "unknown client_id") }

        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], !code.isEmpty else { return oauthError(status: 400, code: "invalid_request", description: "code is required") }
            let digest = Self.sha256(code)
            guard let record = lock.withLock({ codes.removeValue(forKey: digest) }), record.expiresAt > Date() else {
                return oauthError(status: 400, code: "invalid_grant", description: "unknown or expired authorization code")
            }
            if let redirect = form["redirect_uri"], redirect != record.redirectURI {
                return oauthError(status: 400, code: "invalid_grant", description: "redirect_uri mismatch")
            }
            guard let verifier = form["code_verifier"], Self.validPKCE(verifier) else {
                return oauthError(status: 400, code: "invalid_request", description: "valid code_verifier required")
            }
            guard Self.pkceChallenge(verifier) == record.challenge else {
                return oauthError(status: 400, code: "invalid_grant", description: "PKCE verification failed")
            }
            return issueTokens(audience: record.resource)

        case "refresh_token":
            guard let token = form["refresh_token"], !token.isEmpty else { return oauthError(status: 400, code: "invalid_request", description: "refresh_token is required") }
            let digest = Self.sha256(token)
            let now = Date().timeIntervalSince1970
            guard let record = lock.withLock({ () -> StoredToken? in
                sweepLocked(now: now)
                return refresh.removeValue(forKey: digest)
            }), record.expiresAt > now else {
                return oauthError(status: 400, code: "invalid_grant", description: "unknown or expired refresh token")
            }
            return issueTokens(audience: record.audience)

        default:
            return oauthError(status: 400, code: "unsupported_grant_type", description: "unsupported grant_type")
        }
    }

    private func revokePOST(body: Data?) -> NeoYOAuthHTTPResponse {
        let form = Self.form(body)
        if let token = form["token"] {
            let digest = Self.sha256(token)
            lock.withLock {
                access.removeValue(forKey: digest)
                refresh.removeValue(forKey: digest)
                saveStoreLocked()
            }
        }
        return NeoYOAuthHTTPResponse(status: 200, headers: ["Cache-Control": "no-store"])
    }

    private func issueTokens(audience: String?) -> NeoYOAuthHTTPResponse {
        let now = Date().timeIntervalSince1970
        let accessToken = Self.randomToken(bytes: 32)
        let refreshToken = Self.randomToken(bytes: 32)
        let accessRecord = StoredToken(digest: Self.sha256(accessToken), clientID: clientID, audience: audience, expiresAt: now + accessTTL)
        let refreshRecord = StoredToken(digest: Self.sha256(refreshToken), clientID: clientID, audience: audience, expiresAt: now + refreshTTL)
        lock.withLock {
            sweepLocked(now: now)
            access[accessRecord.digest] = accessRecord
            refresh[refreshRecord.digest] = refreshRecord
            saveStoreLocked()
        }
        return json(status: 200, [
            "access_token": accessToken,
            "token_type": "Bearer",
            "expires_in": Int(accessTTL),
            "refresh_token": refreshToken,
            "scope": scope
        ], headers: ["Cache-Control": "no-store"])
    }

    private func oauthRedirect(_ redirect: String, params: [String: String]) -> NeoYOAuthHTTPResponse {
        var components = URLComponents(string: redirect)!
        let newItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = (components.queryItems ?? []) + newItems
        return NeoYOAuthHTTPResponse(status: 302, headers: ["Location": components.url!.absoluteString, "Cache-Control": "no-store"])
    }

    private func errorParams(_ code: String, state: String?, issuer: String) -> [String: String] {
        var result = ["error": code, "iss": issuer]
        if let state { result["state"] = state }
        return result
    }

    private func oauthError(status: Int, code: String, description: String) -> NeoYOAuthHTTPResponse {
        json(status: status, ["error": code, "error_description": description], headers: ["Cache-Control": "no-store"])
    }

    private func html(status: Int, title: String, body: String) -> NeoYOAuthHTTPResponse {
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(Self.htmlEscape(title))</title></head><body><h1>\(Self.htmlEscape(title))</h1><p>\(Self.htmlEscape(body))</p></body></html>"
        return NeoYOAuthHTTPResponse(status: status, body: Data(html.utf8), contentType: "text/html; charset=utf-8", headers: ["Cache-Control": "no-store"])
    }

    private func json(status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> NeoYOAuthHTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return NeoYOAuthHTTPResponse(status: status, body: data, headers: headers)
    }

    private func discoveryHeaders() -> [String: String] {
        ["Cache-Control": "no-store", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS"]
    }

    private func publicOrigin(headers: [String: String]) -> String? {
        guard let rawHost = headers["host"], rawHost.range(of: #"^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$"#, options: .regularExpression) != nil else { return nil }
        let proto = headers["x-forwarded-proto"]?.lowercased() == "https" || headers["cf-ray"] != nil ? "https" : "http"
        return "\(proto)://\(rawHost)"
    }

    private func loadStore() {
        lock.withLock {
            guard let data = try? Data(contentsOf: stateURL), let stored = try? JSONDecoder().decode(StoreFile.self, from: data),
                  stored.clientID == clientID, stored.tokenEpoch == tokenEpoch else {
                access = [:]; refresh = [:]; saveStoreLocked(); return
            }
            access = Dictionary(uniqueKeysWithValues: stored.access.map { ($0.digest, $0) })
            refresh = Dictionary(uniqueKeysWithValues: stored.refresh.map { ($0.digest, $0) })
            sweepLocked(now: Date().timeIntervalSince1970)
        }
    }

    private func saveStoreLocked() {
        let file = StoreFile(clientID: clientID, tokenEpoch: tokenEpoch, access: Array(access.values), refresh: Array(refresh.values))
        guard let data = try? JSONEncoder().encode(file) else { return }
        let dir = stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func sweepLocked(now: TimeInterval) {
        access = access.filter { $0.value.expiresAt > now }
        refresh = refresh.filter { $0.value.expiresAt > now }
        if access.count > 256 { access = Dictionary(uniqueKeysWithValues: access.values.sorted { $0.expiresAt > $1.expiresAt }.prefix(256).map { ($0.digest, $0) }) }
        if refresh.count > 256 { refresh = Dictionary(uniqueKeysWithValues: refresh.values.sorted { $0.expiresAt > $1.expiresAt }.prefix(256).map { ($0.digest, $0) }) }
    }

    private func sweepPendingLocked() {
        let now = Date()
        pendingAuth = pendingAuth.filter { $0.value.expiresAt > now }
        codes = codes.filter { $0.value.expiresAt > now }
        if pendingAuth.count > 32 { pendingAuth.removeValue(forKey: pendingAuth.min { $0.value.expiresAt < $1.value.expiresAt }!.key) }
        if codes.count > 32 { codes.removeValue(forKey: codes.min { $0.value.expiresAt < $1.value.expiresAt }!.key) }
    }

    private static func form(_ body: Data?) -> [String: String] {
        guard let body, let string = String(data: body, encoding: .utf8) else { return [:] }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            return object.reduce(into: [:]) { result, pair in
                if pair.value is NSNull { return }
                result[pair.key] = String(describing: pair.value)
            }
        }
        var result: [String: String] = [:]
        for pair in string.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let raw = parts.count > 1 ? String(parts[1]) : ""
            result[key] = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return result
    }

    private static func allowedRedirect(_ value: String) -> Bool {
        if value == "https://chatgpt.com/connector_platform_oauth_redirect" { return true }
        guard let url = URL(string: value), url.scheme == "https", url.host == "chatgpt.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return false }
        return url.path.range(of: #"^/connector/oauth/[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }

    private static func validPKCE(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._~-]{43,128}$"#, options: .regularExpression) != nil
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func randomToken(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ah = Array(SHA256.hash(data: Data(a.utf8)))
        let bh = Array(SHA256.hash(data: Data(b.utf8)))
        var diff: UInt8 = 0
        for i in ah.indices { diff |= ah[i] ^ bh[i] }
        return diff == 0
    }

    private static func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
