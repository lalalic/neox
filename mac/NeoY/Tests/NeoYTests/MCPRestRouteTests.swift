import XCTest
@testable import NeoY

final class MCPRestRouteTests: XCTestCase {
    func testListAndToolPaths() {
        let listing = MCPServer.restRoute("/mcp/rest/short-lived-token")
        XCTAssertEqual(listing?.token, "short-lived-token")
        XCTAssertNil(listing?.tool)

        let call = MCPServer.restRoute("/mcp/rest/short-lived-token/mcp.chat_gateway")
        XCTAssertEqual(call?.token, "short-lived-token")
        XCTAssertEqual(call?.tool, "mcp.chat_gateway")
    }

    func testURLGetListsAndCallsRegisteredTools() async throws {
        let port = UInt16.random(in: 40000...55000)
        let server = await MainActor.run { () -> MCPServer in
            let server = MCPServer(name: "REST test", port: port)
            server.register(name: "rest.probe", description: "Echo a test response",
                            inputSchema: ["type": "object", "properties": [:]]) { _ in
                "rest-probe-ok"
            }
            server.setPrivilegedAccessToken("test-url-token")
            server.setRemoteAllowedTools(["rest.probe"])
            return server
        }
        try await MainActor.run { try server.start() }
        defer { Task { @MainActor in server.stop() } }
        try await Task.sleep(for: .milliseconds(150))

        func request(_ path: String) async throws -> [String: Any] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
            var request = URLRequest(url: url)
            // Pretend the request arrived through the remote tunnel.
            request.setValue("rest-test", forHTTPHeaderField: "cf-ray")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let list = try await request("/mcp/rest/test-url-token")
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { ($0["name"] as? String) == "rest.probe" })

        let call = try await request("/mcp/rest/test-url-token/rest.probe?args=%7B%7D")
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "rest-probe-ok")

        let denied = try await request("/mcp/rest/bad-token/rest.probe")
        XCTAssertNotNil(denied["error"])
    }

    func testEncodedComponentsAndInvalidPaths() {
        XCTAssertEqual(MCPServer.restRoute("/mcp/rest/a%2Bb/shell")?.token, "a+b")
        for path in ["/mcp/rest/", "/mcp/rest/t/", "/mcp/rest/t/shell/extra",
                     "/mcp/rest", "/mcp/rest//shell"] {
            XCTAssertNil(MCPServer.restRoute(path), path)
        }
    }
}
