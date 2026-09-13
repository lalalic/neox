import XCTest

final class PhoneTransactionUITests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9223/mcp")!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPhoneTransactionStartAndEndAreVisibleToUser() async throws {
        let app = XCUIApplication()
        app.launch()

        let startText = try await callTool(
            "phone.transaction.start",
            arguments: [
                "label": "Vlog media transfer",
                "reason": "Transferring selected photos and videos",
                "timeout_minutes": 5,
            ]
        )
        let transactionID = try XCTUnwrap(jsonObject(in: startText)["transaction_id"] as? String)

        XCTAssertTrue(app.staticTexts["NeoX phone work active"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keep NeoX in the foreground while phone work is active."].exists)
        XCTAssertTrue(app.staticTexts["Vlog media transfer"].exists)
        XCTAssertTrue(app.staticTexts["Transferring selected photos and videos"].exists)

        _ = try await callTool(
            "phone.transaction.end",
            arguments: [
                "transaction_id": transactionID,
                "outcome": "completed",
            ]
        )

        XCTAssertTrue(app.staticTexts["Phone work complete"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "NeoX is released. You can use your phone normally; desktop processing may continue."
            ].exists
        )
        XCTAssertFalse(app.staticTexts["Keep NeoX in the foreground while phone work is active."].exists)
    }

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        var lastError: Error?
        for attempt in 0..<20 {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": attempt + 1,
                    "method": "tools/call",
                    "params": ["name": name, "arguments": arguments],
                ])

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw NSError(domain: "NeoxUITests", code: 1)
                }
                let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let result = try XCTUnwrap(envelope["result"] as? [String: Any])
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                let text = try XCTUnwrap(content.first?["text"] as? String)
                return text
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError ?? NSError(domain: "NeoxUITests", code: 2)
    }

    private func jsonObject(in text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
