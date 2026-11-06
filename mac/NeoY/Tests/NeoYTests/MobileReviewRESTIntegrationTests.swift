import Foundation
import XCTest
@testable import NeoY

final class MobileReviewRESTIntegrationTests: XCTestCase {
    @MainActor
    func testRESTRegistrationNotifyPendingCompleteAndMCPIsolation() async throws {
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("review-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let prior = getenv("NEO_APNS_HOME").map { String(cString: $0) }
        setenv("NEO_APNS_HOME", testRoot.path, 1)
        defer {
            if let prior { setenv("NEO_APNS_HOME", prior, 1) } else { unsetenv("NEO_APNS_HOME") }
            try? FileManager.default.removeItem(at: testRoot)
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runtime/src/core/tools/review.mjs")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: source.path))

        let port: UInt16 = 59839
        let server = MCPServer(name: "review-http-test", port: port)
        let masterCode = "test-master-access-code"
        server.setPrivilegedAccessToken(masterCode)
        NeoYMobileReviewREST.register(on: server, moduleURL: source)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        let origin = "http://127.0.0.1:\(port)"
        let session = URLSession(configuration: .ephemeral)
        func call(_ path: String, method: String = "GET", bearer: String? = nil,
                  json: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: origin + path)!)
            request.httpMethod = method
            request.timeoutInterval = 20
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            if let json {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
            }
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (http.statusCode, payload)
        }
        let token = String(repeating: "a", count: 64)
        let id = UUID().uuidString.lowercased()
        let unauthorized = try await call("/mobile/review/register", method: "POST",
                                          json: ["deviceId": id, "token": token, "environment": "sandbox"])
        XCTAssertEqual(unauthorized.0, 403)
        let oauth = try await call("/mobile/review/pending", bearer: "oauth-bearer")
        XCTAssertEqual(oauth.0, 403)
        let registered = try await call("/mobile/review/register", method: "POST", bearer: masterCode,
                                        json: ["deviceId": id, "token": token, "environment": "sandbox"])
        XCTAssertEqual(registered.1["registered"] as? Bool, true)
        let hash = String(repeating: "b", count: 64)
        let review: [String: Any] = ["id": id, "title": "REST E2E", "contentHash": hash,
                                     "revisionId": "r1", "delivery": "text"]
        let wake = try await call("/mobile/review/notify", method: "POST", json: review)
        XCTAssertEqual(wake.0, 200)
        XCTAssertEqual(wake.1["stored"] as? Bool, true)
        XCTAssertEqual(wake.1["requestId"] as? String, id)
        let pending = try await call("/mobile/review/pending", bearer: masterCode)
        XCTAssertEqual(pending.0, 200)
        XCTAssertEqual((pending.1["requests"] as? [[String: Any]])?.first?["id"] as? String, id)
        let completion = try await call("/mobile/review/complete", method: "POST", bearer: masterCode,
                                        json: ["id": id])
        XCTAssertEqual(completion.1["acknowledged"] as? Bool, true)
        let afterComplete = try await call("/mobile/review/pending", bearer: masterCode)
        XCTAssertEqual((afterComplete.1["requests"] as? [[String: Any]])?.count, 0)
        let mcp = try await call("/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 1,
                                                            "method": "tools/list", "params": [:]])
        XCTAssertEqual(mcp.0, 200)
        let tools = (mcp.1["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertFalse(tools.contains { ($0["name"] as? String) == "review" })
    }
}
