import CryptoKit
import XCTest

@testable import NeoY

final class NeoYOAuthTests: XCTestCase {
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
