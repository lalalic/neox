import XCTest
@testable import NeoxApp

@MainActor
final class AutoVlogConsentTests: XCTestCase {
    func testDefaultOffAndUnavailableWithoutMaster() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AutoVlogConsentStore(defaults: defaults)
        XCTAssertNil(store.consent)
        XCTAssertEqual(AutoVlogAvailability.resolve(selectedMaster: "Mac A", consent: store.consent), .off)
        XCTAssertEqual(AutoVlogAvailability.resolve(selectedMaster: nil, consent: store.consent), .noMaster)
    }

    func testOptInPersistsButNeverClaimsActive() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = AutoVlogConsentStore(defaults: defaults)
        first.set(enabled: true, selectedMaster: "Mac A", lookbackDays: 7, maxCandidates: 10)
        let restarted = AutoVlogConsentStore(defaults: defaults)
        XCTAssertEqual(restarted.consent(for: "Mac A")?.enabled, true)
        XCTAssertEqual(restarted.consent(for: "Mac A")?.lookbackDays, 7)
        XCTAssertEqual(AutoVlogAvailability.resolve(selectedMaster: "Mac A", consent: restarted.consent), .pendingMasterSupport)
        restarted.set(enabled: false, selectedMaster: "Mac A", lookbackDays: 7, maxCandidates: 10)
        XCTAssertEqual(AutoVlogAvailability.resolve(selectedMaster: "Mac A", consent: restarted.consent), .off)
    }

    func testConsentDoesNotFollowChangedMasterOrAcceptUnsafeBounds() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AutoVlogConsentStore(defaults: defaults)
        store.set(enabled: true, selectedMaster: "Mac A", lookbackDays: 1, maxCandidates: 5)
        XCTAssertNil(store.consent(for: "Mac B"))
        XCTAssertEqual(AutoVlogAvailability.resolve(selectedMaster: "Mac B", consent: store.consent), .off)
        store.set(enabled: true, selectedMaster: "Mac B", lookbackDays: 31, maxCandidates: 5)
        XCTAssertNil(store.consent(for: "Mac B"))
        XCTAssertEqual(store.consent(for: "Mac A")?.enabled, true)
    }
}
