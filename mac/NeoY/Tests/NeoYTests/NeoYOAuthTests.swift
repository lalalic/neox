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
}
