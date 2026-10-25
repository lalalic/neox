import XCTest
import Darwin
@testable import NeoxApp

final class VNCLoopbackRelayTests: XCTestCase {
    func testRawLoopbackSocketCanListen() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { Darwin.close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(result, 0, "bind errno \\(errno)")
        XCTAssertEqual(Darwin.listen(fd, 1), 0, "listen errno \\(errno)")
    }

    func testLocalClientConnectsToRelay() async throws {
        let endpoint = try XCTUnwrap(URL(string: "wss://127.0.0.1:1/vnc"))
        let relay = try await VNCLoopbackRelay.start(url: endpoint, token: "test-token")
        defer { relay.close() }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = relay.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(result, 0, "connect errno \\(errno)")
    }

    func testListenerStartsOnLocalInterfaceAndCloses() async throws {
        let endpoint = try XCTUnwrap(URL(string: "wss://neoy.example.com/vnc"))
        let relay = try await VNCLoopbackRelay.start(url: endpoint, token: "test-token")
        XCTAssertGreaterThan(relay.port, 0)
        relay.close()
    }
}
