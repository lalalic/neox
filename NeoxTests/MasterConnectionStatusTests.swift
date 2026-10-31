import XCTest
@testable import NeoxApp

@MainActor
final class MasterConnectionStatusTests: XCTestCase {
    func testBonjourAbsenceDoesNotMeanOffline() {
        XCTAssertEqual(StatusView.masterStatus(nearby: false, authenticated: false,
                                               checked: false, hasCredential: true), "Remote")
        XCTAssertEqual(StatusView.masterStatus(nearby: false, authenticated: false,
                                               checked: false, hasCredential: false), "Remote")
    }

    func testAuthenticatedRemoteCanBeOnlineAwayFromWiFi() {
        XCTAssertEqual(StatusView.masterStatus(nearby: false, authenticated: true,
                                               checked: true, hasCredential: true), "Online")
        XCTAssertEqual(StatusView.masterStatus(nearby: true, authenticated: false,
                                               checked: false, hasCredential: false), "Nearby")
    }

    func testFailedCredentialProbeShowsProblemNotOfflineMac() {
        XCTAssertEqual(StatusView.masterStatus(nearby: false, authenticated: false,
                                               checked: true, hasCredential: true), "Connection issue")
    }
}
