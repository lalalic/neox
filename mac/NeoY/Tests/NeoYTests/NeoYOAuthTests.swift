import CryptoKit
import XCTest

@testable import NeoY

final class NeoYOAuthTests: XCTestCase {
    func testDiscoveryMethodNotAllowedAdvertisesSupportedMethods() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-405-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = NeoYOAuthService(
            clientID: "configured-client",
            consentToken: "test-static-token-0123456789abcdef",
            stateURL: directory.appendingPathComponent("native-oauth-state.json")
        )
        let headers = ["host": "neoy.example", "x-forwarded-proto": "https"]
        let path = "/.well-known/oauth-authorization-server"
        let rejected = service.handle(method: "POST", path: path, requestTarget: path,
                                      headers: headers, body: nil)
        XCTAssertEqual(rejected?.status, 405)
        XCTAssertEqual(rejected?.headers["Allow"], "GET, HEAD, OPTIONS")
        let accepted = service.handle(method: "GET", path: path, requestTarget: path,
                                      headers: headers, body: nil)
        XCTAssertEqual(accepted?.status, 200)
    }

    func testNativeOAuthUsesIndependentStateFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gatewayState = directory.appendingPathComponent("oauth-state.json")
        let gatewaySentinel = Data(#"{"v":2,"refresh":[{"d":"sentinel"}]}"#.utf8)
        try gatewaySentinel.write(to: gatewayState)

        let nativeState = directory.appendingPathComponent("native-oauth-state.json")
        _ = NeoYOAuthService(
            clientID: "neo-test-client",
            consentToken: "test-static-token-0123456789abcdef",
            stateURL: nativeState
        )

        XCTAssertEqual(try Data(contentsOf: gatewayState), gatewaySentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nativeState.path))
    }

    func testNativeOAuthImportsConfiguredGatewaySessionOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clientID = "neo-configured-client"
        let consentToken = "test-static-token-0123456789abcdef"
        let accessToken = "existing-access-token"
        let refreshToken = "existing-refresh-token"
        let expires = (Date().timeIntervalSince1970 + 3600) * 1000
        let first = SHA256.hash(data: Data(consentToken.utf8))
        let epoch = SHA256.hash(data: Data(first)).map { String(format: "%02x", $0) }.joined()
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let gateway: [String: Any] = [
            "v": 2,
            "bearerEpoch": epoch,
            "access": [["d": digest(accessToken), "exp": expires, "cid": clientID,
                        "aud": "https://neoy.example", "scope": "mcp"]],
            "refresh": [["d": digest(refreshToken), "exp": expires, "cid": clientID,
                         "aud": "https://neoy.example", "scope": "mcp"]],
        ]
        let gatewayState = directory.appendingPathComponent("oauth-state.json")
        try JSONSerialization.data(withJSONObject: gateway).write(to: gatewayState)
        let originalGatewayData = try Data(contentsOf: gatewayState)

        let service = NeoYOAuthService(
            clientID: clientID, consentToken: consentToken,
            stateURL: directory.appendingPathComponent("native-oauth-state.json"),
            gatewayStateURL: gatewayState
        )
        XCTAssertTrue(service.isAuthorizedBearer(accessToken))
        let response = service.handle(
            method: "POST", path: "/token", requestTarget: "/token",
            headers: ["host": "neoy.example", "content-type": "application/x-www-form-urlencoded"],
            body: Data("grant_type=refresh_token&client_id=\(clientID)&refresh_token=\(refreshToken)".utf8)
        )
        XCTAssertEqual(response?.status, 200)
        XCTAssertEqual(try Data(contentsOf: gatewayState), originalGatewayData)
    }

    func testNativeOAuthImportsDynamicGatewayClientAndSupportsRegistration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-dynamic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuredID = "neo-configured-client"
        let dynamicID = "neo-dcr-0123456789abcdef0123456789abcdef"
        let consentToken = "test-static-token-0123456789abcdef"
        let accessToken = "dynamic-access-token"
        let refreshToken = "dynamic-refresh-token"
        let expires = (Date().timeIntervalSince1970 + 3600) * 1000
        let first = SHA256.hash(data: Data(consentToken.utf8))
        let epoch = SHA256.hash(data: Data(first)).map { String(format: "%02x", $0) }.joined()
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let gateway: [String: Any] = [
            "v": 2,
            "bearerEpoch": epoch,
            "clients": [[
                "id": dynamicID,
                "redirectUris": ["https://chatgpt.com/connector_platform_oauth_redirect"],
                "clientName": "ChatGPT",
                "createdAt": Date().timeIntervalSince1970 * 1000,
            ]],
            "access": [["d": digest(accessToken), "exp": expires, "cid": dynamicID,
                        "aud": "https://neoy.example", "scope": "mcp"]],
            "refresh": [["d": digest(refreshToken), "exp": expires, "cid": dynamicID,
                         "aud": "https://neoy.example", "scope": "mcp"]],
        ]
        let gatewayState = directory.appendingPathComponent("oauth-state.json")
        try JSONSerialization.data(withJSONObject: gateway).write(to: gatewayState)

        let service = NeoYOAuthService(
            clientID: configuredID, consentToken: consentToken,
            stateURL: directory.appendingPathComponent("native-oauth-state.json"),
            gatewayStateURL: gatewayState
        )
        XCTAssertTrue(service.isAuthorizedBearer(accessToken))
        let refreshed = service.handle(
            method: "POST", path: "/token", requestTarget: "/token",
            headers: ["host": "neoy.example", "content-type": "application/x-www-form-urlencoded"],
            body: Data("grant_type=refresh_token&client_id=\(dynamicID)&refresh_token=\(refreshToken)".utf8)
        )
        XCTAssertEqual(refreshed?.status, 200)
        let regularRenew = service.handle(
            method: "POST", path: "/token/renew", requestTarget: "/token/renew",
            headers: ["host": "neoy.example", "authorization": "Bearer \(accessToken)"], body: nil
        )
        XCTAssertEqual(regularRenew?.status, 401, "Standard OAuth access tokens must not self-renew")

        let registration = service.handle(
            method: "POST", path: "/register", requestTarget: "/register",
            headers: ["host": "neoy.example", "content-type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: [
                "redirect_uris": ["https://chatgpt.com/connector_platform_oauth_redirect"],
                "client_name": "ChatGPT",
                "token_endpoint_auth_method": "none",
            ])
        )
        XCTAssertEqual(registration?.status, 201)
    }

    func testClaudeOAuthCallbackRegistrationRequiresExactTrustedURI() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = NeoYOAuthService(
            clientID: "configured-client",
            consentToken: "test-static-token-0123456789abcdef",
            stateURL: directory.appendingPathComponent("native-oauth-state.json")
        )
        let headers = ["host": "neoy.example", "x-forwarded-proto": "https"]
        func register(_ redirect: String) throws -> NeoYOAuthHTTPResponse? {
            service.handle(method: "POST", path: "/register", requestTarget: "/register",
                headers: headers, body: try JSONSerialization.data(withJSONObject: [
                    "client_name": "Claude", "redirect_uris": [redirect],
                    "token_endpoint_auth_method": "none",
                ]))
        }

        let callback = "https://claude.ai/api/mcp/auth_callback"
        let registration = try register(callback)
        XCTAssertEqual(registration?.status, 201)
        let data = try XCTUnwrap(registration?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clientID = try XCTUnwrap(object["client_id"] as? String)
        for untrusted in [
            "http://claude.ai/api/mcp/auth_callback",
            "https://claude.ai.evil.example/api/mcp/auth_callback",
            "https://claude.ai/api/mcp/auth_callback?next=evil",
            "https://claude.ai/api/mcp/other",
        ] {
            XCTAssertEqual(try register(untrusted)?.status, 400, untrusted)
        }

        let target = "/authorize?response_type=code&client_id=\(clientID)"
            + "&redirect_uri=https%3A%2F%2Fclaude.ai%2Fapi%2Fmcp%2Fauth_callback"
            + "&code_challenge=\(String(repeating: "a", count: 43))&code_challenge_method=S256"
        let authorization = service.handle(method: "GET", path: "/authorize", requestTarget: target,
            headers: headers, body: nil)
        XCTAssertEqual(authorization?.status, 200)
        XCTAssertTrue(authorization?.headers["Content-Security-Policy"]?.contains("https://claude.ai") == true)
        XCTAssertTrue(String(data: try XCTUnwrap(authorization?.body), encoding: .utf8)?
            .contains("requesting MCP client") == true)
    }

    func testGrokOAuthCallbackRegistrationAndAuthorization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-grok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = NeoYOAuthService(
            clientID: "configured-client",
            consentToken: "test-static-token-0123456789abcdef",
            stateURL: directory.appendingPathComponent("native-oauth-state.json")
        )
        let headers = ["host": "neoy.example", "x-forwarded-proto": "https"]
        func register(_ redirect: String) throws -> NeoYOAuthHTTPResponse? {
            service.handle(method: "POST", path: "/register", requestTarget: "/register",
                headers: headers, body: try JSONSerialization.data(withJSONObject: [
                    "client_name": "Grok", "redirect_uris": [redirect],
                    "token_endpoint_auth_method": "none",
                ]))
        }

        let callback = "https://grok.com/connectors-oauth-exchange-code/"
        let registration = try register(callback)
        XCTAssertEqual(registration?.status, 201)
        let data = try XCTUnwrap(registration?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clientID = try XCTUnwrap(object["client_id"] as? String)
        for untrusted in [
            "http://grok.com/connectors-oauth-exchange-code/",
            "https://grok.com.evil.example/connectors-oauth-exchange-code/",
            "https://grok.com/connectors-oauth-exchange-code/?next=evil",
            "https://grok.com/connectors-oauth-exchange-code",
            "https://grok.com/other",
        ] {
            XCTAssertEqual(try register(untrusted)?.status, 400, untrusted)
        }

        let target = "/authorize?response_type=code&client_id=\(clientID)"
            + "&redirect_uri=https%3A%2F%2Fgrok.com%2Fconnectors-oauth-exchange-code%2F"
            + "&code_challenge=\(String(repeating: "a", count: 43))&code_challenge_method=S256"
        let authorization = service.handle(method: "GET", path: "/authorize", requestTarget: target,
            headers: headers, body: nil)
        XCTAssertEqual(authorization?.status, 200)
        XCTAssertTrue(authorization?.headers["Content-Security-Policy"]?.contains("https://grok.com") == true)
    }

    func testMuseOAuthCallbackRegistrationAllowsOnlyExactMetaURLs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-muse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = NeoYOAuthService(
            clientID: "configured-client", consentToken: "test-static-token-0123456789abcdef",
            stateURL: directory.appendingPathComponent("native-oauth-state.json")
        )
        let headers = ["host": "neoy.example", "x-forwarded-proto": "https"]
        func register(_ redirect: String) throws -> NeoYOAuthHTTPResponse? {
            service.handle(method: "POST", path: "/register", requestTarget: "/register",
                headers: headers, body: try JSONSerialization.data(withJSONObject: [
                    "client_name": "Meta Muse", "redirect_uris": [redirect],
                    "token_endpoint_auth_method": "none",
                ]))
        }
        let callbacks = [
            "https://muse.ai/api/hatch/oauth/callback",
            "https://agent.meta.ai/api/hatch/oauth/callback",
        ]
        let store = NeoYOAuthRedirectStore(directory: directory)
        for callback in callbacks { try store.add(callback) }
        for callback in callbacks {
            let registration = try register(callback)
            XCTAssertEqual(registration?.status, 201, callback)
            let data = try XCTUnwrap(registration?.body)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let clientID = try XCTUnwrap(object["client_id"] as? String)
            var query = URLComponents()
            query.path = "/authorize"
            query.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: callback),
                URLQueryItem(name: "code_challenge", value: String(repeating: "a", count: 43)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            let authorization = service.handle(method: "GET", path: "/authorize",
                requestTarget: try XCTUnwrap(query.string), headers: headers, body: nil)
            XCTAssertEqual(authorization?.status, 200, callback)
        }
        for invalid in [
            "http://muse.ai/api/hatch/oauth/callback",
            "https://muse.ai.evil.example/api/hatch/oauth/callback",
            "https://muse.ai/api/hatch/oauth/callback?next=evil",
            "https://muse.ai/api/hatch/oauth/callback/",
            "https://agent.meta.ai.evil.example/api/hatch/oauth/callback",
        ] {
            XCTAssertEqual(try register(invalid)?.status, 400, invalid)
        }
    }

    func testConfiguredOAuthCallbacksPersistAndRegisterWithoutRebuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-configurable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NeoYOAuthRedirectStore(directory: directory)
        let service = NeoYOAuthService(
            clientID: "configured-client", consentToken: "test-static-token-0123456789abcdef",
            stateURL: directory.appendingPathComponent("state.json")
        )
        let callback = "https://example.app/oauth/callback"
        let body = try JSONSerialization.data(withJSONObject: [
            "client_name": "Future Agent", "redirect_uris": [callback],
            "token_endpoint_auth_method": "none",
        ])
        let headers = ["host": "neoy.example", "x-forwarded-proto": "https"]
        func register() -> NeoYOAuthHTTPResponse? {
            service.handle(method: "POST", path: "/register", requestTarget: "/register",
                headers: headers, body: body)
        }
        XCTAssertEqual(register()?.status, 400)
        XCTAssertEqual(try store.add(callback), [callback])
        XCTAssertEqual(try NeoYOAuthRedirectStore(directory: directory).list(), [callback])
        let created = try XCTUnwrap(register())
        XCTAssertEqual(created.status, 201)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(created.body)) as? [String: Any])
        let clientID = try XCTUnwrap(json["client_id"] as? String)
        let target = "/authorize?response_type=code&client_id=\(clientID)"
            + "&redirect_uri=https%3A%2F%2Fexample.app%2Foauth%2Fcallback"
            + "&code_challenge=\(String(repeating: "a", count: 43))&code_challenge_method=S256"
        let authorized = service.handle(method: "GET", path: "/authorize", requestTarget: target,
            headers: headers, body: nil)
        XCTAssertEqual(authorized?.status, 200)
        XCTAssertTrue(authorized?.headers["Content-Security-Policy"]?.contains("form-action 'self' https://example.app;") == true)
        XCTAssertEqual(try store.remove(callback), [])
        XCTAssertEqual(register()?.status, 400)
        XCTAssertEqual(service.handle(method: "GET", path: "/authorize", requestTarget: target,
            headers: headers, body: nil)?.status, 400)
    }

    func testConfiguredOAuthCallbacksRejectUnsafeURLsAndMalformedState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-config-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NeoYOAuthRedirectStore(directory: directory)
        for bad in [
            "http://example.com/oauth/callback", "https://example.com/",
            "https://example.com/oauth/callback?next=x", "https://example.com/oauth/callback#fragment",
            "https://example.com.evil.test:8443/oauth/callback", "https://*.example.com/oauth/callback",
            "https://user:password@example.com/oauth/callback", "https://localhost/oauth/callback",
        ] {
            XCTAssertThrowsError(try store.add(bad), bad)
        }
        XCTAssertEqual(try store.list(), [])
        let file = directory.appendingPathComponent("oauth-redirects.json")
        try Data(#"{"version":1,"redirects":["https://*.example.com/oauth/callback"]}"#.utf8).write(to: file)
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.add("https://example.app/oauth/callback"))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("*.example.com"),
                      "Invalid config must be preserved, not silently overwritten")
    }

    func testInteractiveAccessTokenSelfRenewsWithoutRefreshSecret() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-oauth-interactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("native-oauth-state.json")
        let coreSecret = "test-static-token-0123456789abcdef"
        let service = NeoYOAuthService(clientID: "configured-client", consentToken: coreSecret, stateURL: state)
        let headers = ["host": "neoy.example", "x-forwarded-proto": "https"]
        func object(_ response: NeoYOAuthHTTPResponse?) throws -> [String: Any] {
            let data = try XCTUnwrap(response?.body)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let callbackURI = "http://127.0.0.1:8765/neo/oauth/callback"
        let registration = service.handle(method: "POST", path: "/register", requestTarget: "/register",
            headers: headers, body: try JSONSerialization.data(withJSONObject: [
                "client_name": "Z.ai interactive", "redirect_uris": [callbackURI],
                "token_endpoint_auth_method": "none",
            ]))
        let clientID = try XCTUnwrap(object(registration)["client_id"] as? String)
        let verifier = String(repeating: "a", count: 43)
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = digest.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var query = URLComponents()
        query.path = "/authorize"
        query.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: callbackURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: "test123"),
        ]
        let target = try XCTUnwrap(query.string)
        let authorization = service.handle(method: "GET", path: "/authorize", requestTarget: target, headers: headers, body: nil)
        XCTAssertEqual(authorization?.status, 200)
        let page = String(decoding: try XCTUnwrap(authorization?.body), as: UTF8.self)
        let ridPattern = try NSRegularExpression(pattern: "name=\"rid\" value=\"([^\"]+)\"")
        let match = try XCTUnwrap(ridPattern.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)))
        let ridRange = try XCTUnwrap(Range(match.range(at: 1), in: page))
        let rid = String(page[ridRange])
        let approval = service.handle(method: "POST", path: "/authorize", requestTarget: "/authorize",
            headers: headers, body: Data("rid=\(rid)&token=\(coreSecret)".utf8))
        XCTAssertEqual(approval?.status, 302)
        let redirect = try XCTUnwrap(approval?.headers["Location"])
        let code = try XCTUnwrap(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let tokenRequest = "grant_type=authorization_code&client_id=\(clientID)&code=\(code)&code_verifier=\(verifier)"
        let tokenResponse = service.handle(method: "POST", path: "/token", requestTarget: "/token",
            headers: headers, body: Data(tokenRequest.utf8))
        XCTAssertEqual(tokenResponse?.status, 200)
        let initial = try object(tokenResponse)
        let accessToken = try XCTUnwrap(initial["access_token"] as? String)
        XCTAssertEqual(initial["expires_in"] as? Int, 3600)
        XCTAssertEqual(initial["session_expires_in"] as? Int, 8 * 3600)
        XCTAssertNil(initial["refresh_token"], "Interactive clients must not receive 30-day refresh secrets")
        XCTAssertTrue(service.isAuthorizedBearer(accessToken))

        let renewedResponse = service.handle(method: "POST", path: "/token/renew", requestTarget: "/token/renew",
            headers: headers.merging(["authorization": "Bearer \(accessToken)"]) { _, value in value }, body: nil)
        XCTAssertEqual(renewedResponse?.status, 200)
        let renewed = try object(renewedResponse)
        let nextToken = try XCTUnwrap(renewed["access_token"] as? String)
        XCTAssertNotEqual(nextToken, accessToken)
        XCTAssertEqual(renewed["expires_in"] as? Int, 3600)
        XCTAssertLessThanOrEqual(renewed["session_expires_in"] as? Int ?? .max, 8 * 3600)
        XCTAssertNil(renewed["refresh_token"])
        XCTAssertFalse(service.isAuthorizedBearer(accessToken), "Previous token must be unusable after rotation")
        XCTAssertTrue(service.isAuthorizedBearer(nextToken))
        let repeated = service.handle(method: "POST", path: "/token/renew", requestTarget: "/token/renew",
            headers: headers.merging(["authorization": "Bearer \(accessToken)"]) { _, value in value }, body: nil)
        XCTAssertEqual(repeated?.status, 401)
        let operatorAttempt = service.handle(method: "POST", path: "/token/renew", requestTarget: "/token/renew",
            headers: headers.merging(["authorization": "Bearer \(coreSecret)"]) { _, value in value }, body: nil)
        XCTAssertEqual(operatorAttempt?.status, 401)

        // A persisted session past its original deadline must never re-open.
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        var accessRecords = try XCTUnwrap(stored["access"] as? [[String: Any]])
        XCTAssertEqual(accessRecords.count, 1)
        accessRecords[0]["renewUntil"] = Date().timeIntervalSince1970 - 10
        stored["access"] = accessRecords
        try JSONSerialization.data(withJSONObject: stored).write(to: state, options: .atomic)
        let restarted = NeoYOAuthService(clientID: "configured-client", consentToken: coreSecret, stateURL: state)
        let deadlineAttempt = restarted.handle(method: "POST", path: "/token/renew", requestTarget: "/token/renew",
            headers: headers.merging(["authorization": "Bearer \(nextToken)"]) { _, value in value }, body: nil)
        XCTAssertEqual(deadlineAttempt?.status, 401)
    }
}
