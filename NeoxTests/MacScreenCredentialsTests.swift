import XCTest
@testable import NeoxApp

final class MacScreenCredentialsTests: XCTestCase {
    func testSecureCredentialsCanBeSavedReadAndRemoved() throws {
        let endpoint = "https://example.invalid/mcp"
        defer { MacScreenCredentials.delete(for: endpoint) }
        try MacScreenCredentials.save(username: "test-user", password: "test-secret", for: endpoint)
        let saved = try XCTUnwrap(MacScreenCredentials.load(for: endpoint))
        XCTAssertEqual(saved.username, "test-user")
        XCTAssertEqual(saved.password, "test-secret")
        MacScreenCredentials.delete(for: endpoint)
        XCTAssertNil(MacScreenCredentials.load(for: endpoint))
    }
}
