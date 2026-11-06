import XCTest
@testable import NeoY

final class MobileReviewAuthorizationTests: XCTestCase {
    private let master = "existing-master-access-code"

    func testRemoteReviewOnlyAcceptsMasterCode() {
        let path = "/mobile/review/pending"
        XCTAssertTrue(NeoYMobileReviewREST.allowed(path: path, isLocal: false,
            headers: ["authorization": "Bearer \(master)"], masterAccessCode: master))
        XCTAssertFalse(NeoYMobileReviewREST.allowed(path: path, isLocal: false,
            headers: ["authorization": "Bearer oauth-client-token"], masterAccessCode: master))
        XCTAssertFalse(NeoYMobileReviewREST.allowed(path: path, isLocal: false,
            headers: [:], masterAccessCode: master))
        XCTAssertFalse(NeoYMobileReviewREST.allowed(path: path, isLocal: true,
            headers: [:], masterAccessCode: master))
    }

    func testNotifyIsLocalOnlyWithoutProxyOrBrowserOrigin() {
        let path = "/mobile/review/notify"
        XCTAssertTrue(NeoYMobileReviewREST.allowed(path: path, isLocal: true,
            headers: ["host": "127.0.0.1:6767"], masterAccessCode: master))
        for headers in [
            ["host": "neo.example.com"],
            ["host": "127.0.0.1:6767", "x-forwarded-for": "192.0.2.1"],
            ["host": "127.0.0.1:6767", "cf-ray": "test"],
            ["host": "127.0.0.1:6767", "origin": "https://evil.example"],
        ] {
            XCTAssertFalse(NeoYMobileReviewREST.allowed(path: path, isLocal: true,
                headers: headers, masterAccessCode: master))
        }
        XCTAssertFalse(NeoYMobileReviewREST.allowed(path: path, isLocal: false,
            headers: ["host": "127.0.0.1:6767"], masterAccessCode: master))
    }

    func testReviewRESTNotPublishedToMCPAgentsOrCluster() {
        XCTAssertFalse(NeoYCoreRuntime.toolNames.contains("review"))
        XCTAssertFalse(NeoYRemoteToolCatalog.coreToolNames.contains("review"))
        XCTAssertEqual(NeoYMobileReviewREST.actions.count, 4)
    }
}
