import XCTest

@testable import NeoY

final class VNCTunnelTests: XCTestCase {
    func testUnauthenticatedProxiedWebSocketIsDenied() async throws {
        let (server, port) = try await MainActor.run { try Self.makeServer() }
        defer { Task { @MainActor in server.stop() } }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/vnc")!)
        request.httpMethod = "GET"
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        request.setValue(Data(repeating: 3, count: 16).base64EncodedString(), forHTTPHeaderField: "Sec-WebSocket-Key")
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("test-cloud-request", forHTTPHeaderField: "CF-Ray")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    }

    func testLocalWebSocketStreamsRFBGreetingWhenScreenSharingIsAvailable() async throws {
        let (server, port) = try await MainActor.run { try Self.makeServer() }
        defer { Task { @MainActor in server.stop() } }

        let credential = Data(Self.testToken.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let raw = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/vnc")!,
            protocols: ["binary", "neo-auth." + credential]
        )
        raw.resume()
        defer { raw.cancel(with: .normalClosure, reason: nil) }

        do {
            let greeting = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask { try await raw.receive() }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            guard case .data(let bytes) = greeting else {
                XCTFail("RFB greeting must be binary")
                return
            }
            XCTAssertTrue(String(data: bytes, encoding: .ascii)?.hasPrefix("RFB 003.") == true)
            try await raw.send(.data(bytes))
            let response = try await raw.receive()
            guard case .data(let offered) = response, let count = offered.first else {
                XCTFail("RFB security list must be binary")
                return
            }
            let securityTypes = Array(offered.dropFirst().prefix(Int(count)))
            XCTAssertEqual(securityTypes.count, Int(count))
            XCTAssertTrue(securityTypes.contains(30), "Mac should offer Apple Remote Desktop authentication")
        } catch {
            throw XCTSkip("Local macOS Screen Sharing is not available for this integration test: \(error)")
        }
    }

    private static let testToken = "vnc-gateway-integration-test-only"

    @MainActor
    private static func makeServer() throws -> (MCPServer, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 30000...60000)
            let server = MCPServer(name: "vnc-test", port: port)
            do {
                server.setPrivilegedAccessToken(testToken)
                try server.start()
                return (server, port)
            } catch {
                server.stop()
            }
        }
        throw CocoaError(.executableLoad)
    }
}
