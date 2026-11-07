import XCTest

/// Real app UI + MCP socket contract: the shared SPM package is not just compiling.
final class AppCopilotPackageUITests: XCTestCase {
    @MainActor
    func testPilotSnapshotAndDemoCaptionThroughMCP() async throws {
        let app = XCUIApplication()
        app.launch()

        let snapshot = try await call("agent.pilot", args: ["command": "snapshot"])
        XCTAssertTrue(snapshot.contains("["), "Expected a screen header: \(snapshot.prefix(200))")
        XCTAssertTrue(snapshot.contains("r0"), "Expected accessible element refs: \(snapshot.prefix(350))")

        let found = try await call("agent.pilot", args: ["command": "find", "text": "Review Inbox"])
        XCTAssertTrue(found.localizedCaseInsensitiveContains("Remote Mac"))

        let caption = "AppCopilotKit live demo verified"
        let result = try await call("agent.demo", args: ["command": "caption", "text": caption])
        XCTAssertTrue(result.localizedCaseInsensitiveContains("caption"))
        XCTAssertTrue(app.staticTexts[caption].waitForExistence(timeout: 5), "The demo overlay must actually appear")
        _ = try await call("agent.demo", args: ["command": "clear"])
    }

    private func call(_ name: String, args: [String: Any]) async throws -> String {
        var lastError: Error?
        for attempt in 0..<30 {
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:9223/mcp")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": ["name": name, "arguments": args]
                ])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw NSError(domain: "AppCopilotUITest", code: 1)
                }
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let result = try XCTUnwrap(envelope["result"] as? [String: Any])
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                return try XCTUnwrap(content.first?["text"] as? String)
            } catch {
                lastError = error
                if attempt == 29 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw lastError ?? NSError(domain: "AppCopilotUITest", code: 2)
    }
}
