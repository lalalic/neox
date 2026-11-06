import XCTest
@testable import NeoY

final class MobileReviewAuthorizationTests: XCTestCase {
    func testOnlyMasterAccessCodeCanAccessRemoteMobileReview() {
        XCTAssertTrue(MCPServer.mobileReviewAllowed(isLocal: true, masterAccessCodeAuthorized: false))
        XCTAssertTrue(MCPServer.mobileReviewAllowed(isLocal: false, masterAccessCodeAuthorized: true))
        XCTAssertFalse(MCPServer.mobileReviewAllowed(isLocal: false, masterAccessCodeAuthorized: false))
    }

    func testClusterCannotProxyPrivateMobileReview() {
        XCTAssertFalse(NeoYNodeService.allowedRemoteCoreTools.contains("review"))
        XCTAssertTrue(NeoYNodeService.allowedRemoteCoreTools.contains("status"))
    }
}
