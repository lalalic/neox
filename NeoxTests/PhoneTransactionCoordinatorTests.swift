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

    func testDuplicateEndRemainsIdempotentAfterDismissal() {
        let coordinator = PhoneTransactionCoordinator()
        let started = Date(timeIntervalSince1970: 1_500)

        guard let transaction = coordinator.start(
            label: "Vlog",
            reason: "Exporting media",
            timeoutMinutes: 30,
            at: started
        ) else {
            return XCTFail("Expected transaction to start")
        }

        guard case .released(let ended) = coordinator.end(
            id: transaction.id,
            outcome: .completed,
            at: started.addingTimeInterval(10)
        ) else {
            return XCTFail("Expected matching end to release")
        }

        coordinator.dismissReleased()
        XCTAssertNil(coordinator.current)
        XCTAssertEqual(
            coordinator.end(id: transaction.id, outcome: .completed, at: started.addingTimeInterval(70)),
            .alreadyReleased(ended)
        )
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

    func testDisplayTextCollapsesWhitespace() {
        XCTAssertEqual(
            PhoneTransactionTools.displayText("Vlog\n\t export  run ", fallback: "Fallback"),
            "Vlog export run"
        )
    }

    func testTimeoutSchemaExposesBounds() throws {
        let start = try XCTUnwrap(
            PhoneTransactionTools.tools().first { $0.name == "phone.transaction.start" }
        )
        guard case .object(let parameters)? = start.parameters,
              case .object(let properties)? = parameters["properties"],
              case .object(let timeout)? = properties["timeout_minutes"] else {
            return XCTFail("Expected timeout_minutes schema object")
        }

        XCTAssertEqual(timeout["type"], .string("integer"))
        XCTAssertEqual(timeout["default"], .int(30))
        XCTAssertEqual(timeout["minimum"], .int(1))
        XCTAssertEqual(timeout["maximum"], .int(240))
    }

    func testReleaseMessagesDescribePhoneWorkOnly() {
        let started = Date(timeIntervalSince1970: 2_500)
        let transaction = PhoneTransactionSnapshot(
            label: "Vlog",
            reason: "Exporting media",
            startedAt: started,
            timeoutMinutes: 30
        )

        for (state, phrase) in [
            (PhoneTransactionState.completed, "Phone work complete"),
            (.failed, "Phone work failed"),
            (.cancelled, "Phone work cancelled"),
            (.timeout, "Phone work timed out"),
        ] {
            let message = PhoneTransactionTools.endedJSON(
                transaction.finished(state: state, at: started.addingTimeInterval(10)),
                alreadyReleased: false
            )
            XCTAssertTrue(message.contains(phrase))
            XCTAssertTrue(message.contains("NeoX is released"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("desktop workflow"))
        }
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
