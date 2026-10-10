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
}
