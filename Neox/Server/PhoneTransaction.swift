import Foundation

enum PhoneTransactionState: Equatable {
    case active
    case completed
    case failed
    case cancelled
    case timeout
}

struct PhoneTransactionSnapshot: Equatable {
    let id: UUID
    let label: String
    let reason: String?
    let startedAt: Date
    let expiresAt: Date
    let timeoutMinutes: Int
    private(set) var endedAt: Date?
    private(set) var state: PhoneTransactionState

    init(
        id: UUID = UUID(),
        label: String,
        reason: String?,
        startedAt: Date,
        timeoutMinutes: Int
    ) {
        self.id = id
        self.label = label
        self.reason = reason
        self.startedAt = startedAt
        expiresAt = startedAt.addingTimeInterval(Double(timeoutMinutes) * 60)
        self.timeoutMinutes = timeoutMinutes
        endedAt = nil
        state = .active
    }

    func isExpired(at now: Date) -> Bool {
        state == .active && now >= expiresAt
    }

    func finished(state: PhoneTransactionState, at now: Date) -> Self {
        var finished = self
        finished.endedAt = min(max(now, startedAt), expiresAt)
        finished.state = state
        return finished
    }
}

enum PhoneTransactionEndResult: Equatable {
    case released(PhoneTransactionSnapshot)
    case alreadyReleased(PhoneTransactionSnapshot)
    case mismatched(PhoneTransactionSnapshot?)
    case notFound
}

@MainActor
final class PhoneTransactionCoordinator {
    private(set) var releasedTransaction: PhoneTransactionSnapshot?
    private var isReleasedTransactionDismissed = false
    private var activeTransaction: PhoneTransactionSnapshot?

    var current: PhoneTransactionSnapshot? {
        activeTransaction ?? (isReleasedTransactionDismissed ? nil : releasedTransaction)
    }

    func dismissReleased() {
        isReleasedTransactionDismissed = true
    }

    @discardableResult
    func start(
        label: String,
        reason: String?,
        timeoutMinutes: Int,
        at now: Date = .now
    ) -> PhoneTransactionSnapshot? {
        refresh(at: now)
        guard activeTransaction == nil else { return nil }

        releasedTransaction = nil
        isReleasedTransactionDismissed = false

        let transaction = PhoneTransactionSnapshot(
            label: label,
            reason: reason,
            startedAt: now,
            timeoutMinutes: timeoutMinutes
        )
        activeTransaction = transaction
        return transaction
    }

    func end(
        id: UUID,
        outcome: PhoneTransactionState,
        at now: Date = .now
    ) -> PhoneTransactionEndResult {
        refresh(at: now)

        guard let transaction = activeTransaction else {
            guard let releasedTransaction else { return .notFound }
            return releasedTransaction.id == id
                ? .alreadyReleased(releasedTransaction)
                : .mismatched(nil)
        }

        guard transaction.id == id else { return .mismatched(transaction) }

        let ended = transaction.finished(
            state: transaction.isExpired(at: now) ? .timeout : outcome,
            at: now
        )

        activeTransaction = nil
        releasedTransaction = ended
        return .released(ended)
    }

    @discardableResult
    func refresh(at now: Date = .now) -> PhoneTransactionSnapshot? {
        guard let transaction = activeTransaction, transaction.isExpired(at: now) else {
            return activeTransaction
        }

        let expired = transaction.finished(state: .timeout, at: transaction.expiresAt)
        activeTransaction = nil
        releasedTransaction = expired
        return expired
    }
}
