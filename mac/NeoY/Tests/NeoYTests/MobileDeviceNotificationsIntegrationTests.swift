import Foundation
import XCTest
@testable import NeoY

final class MobileDeviceNotificationsIntegrationTests: XCTestCase {
    @MainActor
    func testDeviceRegistrationAndGenericNotificationAreProtectedAndDoNotNeedNode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prior = getenv("NEO_APNS_HOME").map { String(cString: $0) }
        setenv("NEO_APNS_HOME", root.path, 1)
        defer {
            if let prior { setenv("NEO_APNS_HOME", prior, 1) } else { unsetenv("NEO_APNS_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        let port: UInt16 = 59839
        let server = MCPServer(name: "device-http-test", port: port)
        let masterCode = "test-master-access-code"
        server.setPrivilegedAccessToken(masterCode)
        NeoYMobileDeviceNotifications.register(on: server)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let origin = "http://127.0.0.1:\(port)"
        let session = URLSession(configuration: .ephemeral)
        func call(_ path: String, bearer: String? = nil, json: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: origin + path)!)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            if let json {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
            }
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (http.statusCode, body)
        }
        let device = UUID().uuidString.lowercased()
        let firstPair = try await call("/mobile/device/register", bearer: masterCode,
                                       json: ["deviceId": device])
        XCTAssertEqual(firstPair.1["registered"] as? Bool, true)
        let registration: [String: Any] = ["deviceId": device, "token": String(repeating: "a", count: 64), "environment": "sandbox"]
        let unauthorized = try await call("/mobile/device/register", json: registration)
        XCTAssertEqual(unauthorized.0, 403)
        let acknowledged = try await call("/mobile/device/register", bearer: masterCode, json: registration)
        XCTAssertEqual(acknowledged.1["registered"] as? Bool, true)
        let stored = try Data(contentsOf: root.appendingPathComponent("devices.json"))
        let database = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertNotNil((database["devices"] as? [String: Any])?[device])
        let notification = try await call("/mobile/notify", json: ["id": device, "title": "Test", "body": "Ready", "payload": ["neoReviewRequestId": device]])
        XCTAssertEqual(notification.1["accepted"] as? Bool, false)
        let oldRoute = try await call("/mobile/review/pending")
        XCTAssertEqual(oldRoute.0, 404)
    }
}
