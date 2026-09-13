import XCTest

@testable import NeoxApp

@MainActor
final class PhoneTransactionCoordinatorTests: XCTestCase {
    func testEndsMatchingTransactionAndIsIdempotent() {
        let coordinator = PhoneTransactionCoordinator()
        let started = Date(timeIntervalSince1970: 1_000)

        let transaction = coordinator.start(
            label: "Vlog",
            reason: "Exporting media",
            timeoutMinutes: 30,
            at: started
        )

        guard let transaction else { return XCTFail("Expected transaction to start") }
        guard case .released(let ended) = coordinator.end(
            id: transaction.id,
            outcome: .completed,
            at: started.addingTimeInterval(10)
        ) else {
            return XCTFail("Expected matching end to release")
        }

        XCTAssertEqual(ended.state, .completed)
        guard case .alreadyReleased(let duplicate) = coordinator.end(
            id: ended.id,
            outcome: .cancelled,
            at: started.addingTimeInterval(20)
        ) else {
            return XCTFail("Expected duplicate end to be idempotent")
        }

        XCTAssertEqual(duplicate, ended)
    }

    func testMismatchedEndDoesNotRelease() {
        let coordinator = PhoneTransactionCoordinator()
        let transaction = coordinator.start(
            label: "Vlog",
            reason: nil,
            timeoutMinutes: 30,
            at: .now
        )

        guard let transaction else { return XCTFail("Expected transaction to start") }
        XCTAssertEqual(
            coordinator.end(id: UUID(), outcome: .completed, at: .now),
            .mismatched(transaction)
        )
        XCTAssertEqual(coordinator.current, transaction)
    }

    func testExpiredTransactionTimesOutAndAllowsRestart() {
        let coordinator = PhoneTransactionCoordinator()
        let started = Date(timeIntervalSince1970: 2_000)

        let transaction = coordinator.start(
            label: "Vlog",
            reason: nil,
            timeoutMinutes: 1,
            at: started
        )
        let expired = coordinator.refresh(at: started.addingTimeInterval(61))

        XCTAssertEqual(transaction?.state, .active)
        XCTAssertEqual(expired?.state, .timeout)
        XCTAssertNil(coordinator.refresh(at: started.addingTimeInterval(62)))

        let replacement = coordinator.start(
            label: "Retry",
            reason: nil,
            timeoutMinutes: 1,
            at: started.addingTimeInterval(62)
        )
        XCTAssertEqual(replacement?.state, .active)
    }
}
