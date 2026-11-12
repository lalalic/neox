import XCTest
@testable import NeoY

final class MobileDeviceNotificationsAuthorizationTests: XCTestCase {
    private let master = "existing-master-access-code"

    func testDeviceRegistrationRequiresMasterAccessCode() {
        let path = NeoYMobileDeviceNotifications.registration
        XCTAssertTrue(NeoYMobileDeviceNotifications.allowed(path: path, isLocal: false,
            headers: ["authorization": "Bearer \(master)"], masterAccessCode: master))
        XCTAssertFalse(NeoYMobileDeviceNotifications.allowed(path: path, isLocal: false,
            headers: ["authorization": "Bearer oauth-client-token"], masterAccessCode: master))
        XCTAssertFalse(NeoYMobileDeviceNotifications.allowed(path: path, isLocal: true,
            headers: [:], masterAccessCode: master))
    }

    func testNotificationSendIsLoopbackOnlyWithoutProxyOrBrowserOrigin() {
        let path = NeoYMobileDeviceNotifications.notify
        XCTAssertTrue(NeoYMobileDeviceNotifications.allowed(path: path, isLocal: true,
            headers: ["host": "127.0.0.1:6767"], masterAccessCode: master))
        for headers in [
            ["host": "neo.example.com"],
            ["host": "127.0.0.1:6767", "x-forwarded-for": "192.0.2.1"],
            ["host": "127.0.0.1:6767", "cf-ray": "test"],
            ["host": "127.0.0.1:6767", "origin": "https://evil.example"],
        ] {
            XCTAssertFalse(NeoYMobileDeviceNotifications.allowed(path: path, isLocal: true,
                headers: headers, masterAccessCode: master))
        }
        XCTAssertFalse(NeoYMobileDeviceNotifications.allowed(path: path, isLocal: false,
            headers: ["host": "127.0.0.1:6767"], masterAccessCode: master))
    }

    func testNotificationRoutesDoNotPublishAsCoreMCPTools() {
        XCTAssertFalse(NeoYCoreRuntime.toolNames.contains("review"))
        XCTAssertFalse(NeoYRemoteToolCatalog.coreToolNames.contains("review"))
        XCTAssertEqual(NeoYMobileDeviceNotifications.actions.count, 2)
        XCTAssertTrue(MCPServer.requiresMasterCode("markcut.review.preview.acquire"))
        XCTAssertTrue(MCPServer.requiresMasterCode("review.preview.acquire"))
        XCTAssertFalse(MCPServer.requiresMasterCode("markcut.review.preview"))
    }
}
