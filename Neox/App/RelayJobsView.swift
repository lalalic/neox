import SwiftUI

/// Display-only Relay job metadata. Prompts, objectives and paths are ignored.
struct RelayJob: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let repository: String
    let status: String
    let updatedAt: String
    /// Only the authenticated gateway may assert this after checking its PR.
    /// The current chat_jobs contract omits it, so cancellation stays hidden.
    let gatewayAllowsCancellation: Bool

    init?(wire: [String: Any]) {
        guard let rawID = wire["id"] as? String,
              let id = Self.clean(rawID, limit: 64), !id.isEmpty,
              let rawStatus = wire["status"] as? String,
              let status = Self.clean(rawStatus, limit: 32), !status.isEmpty else { return nil }
        self.id = id
        self.title = Self.clean(wire["title"] as? String ?? "", limit: 160) ?? ""
        self.repository = Self.clean(wire["repository"] as? String ?? "", limit: 120) ?? ""
        self.status = status
        self.updatedAt = Self.clean(wire["updatedAt"] as? String ?? "", limit: 40) ?? ""
        self.gatewayAllowsCancellation = wire["cancellable"] as? Bool == true
    }

    private static func clean(_ raw: String, limit: Int) -> String? {
        let value = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    var lifecycle: RelayJobLifecycle { RelayJobLifecycle(status: status) }
    var statusName: String { lifecycle.title }
    var isActive: Bool {
        [.planning, .queued, .active, .running, .paused, .blocked].contains(lifecycle)
    }
    var displayTitle: String { title.isEmpty ? "Job \(id)" : title }

    /// Requires explicit gateway capability and a nonterminal Relay state.
    /// This is false for every response from today's chat_jobs contract.
    var canCancel: Bool {
        gatewayAllowsCancellation && [.planning, .queued, .active, .running, .paused, .blocked].contains(lifecycle)
    }
}

enum RelayJobLifecycle: Equatable {
    case planning, queued, active, running, paused, blocked
    case completed, succeeded, failed, cancelled, unknown

    init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "PLANNING": self = .planning
        case "QUEUED", "DRAFT": self = .queued
        case "ACTIVE": self = .active
        case "RUNNING": self = .running
        case "PAUSED", "AWAITING_DECISION": self = .paused
        case "BLOCKED": self = .blocked
        case "COMPLETED": self = .completed
        case "SUCCEEDED": self = .succeeded
        case "FAILED": self = .failed
        case "CANCELLED", "CANCELED": self = .cancelled
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .planning: "Planning"
        case .queued: "Queued"
        case .active: "Active"
        case .running: "Running"
        case .paused: "Paused"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .unknown: "Status unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .planning, .queued: "clock"
        case .active: "ellipsis.circle"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .paused: "pause.circle"
        case .blocked: "hand.raised.circle"
        case .completed, .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .planning, .queued, .active, .running: .accentColor
        case .paused, .blocked, .unknown: .secondary
        case .completed, .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    var isRunning: Bool { self == .running }
    var isTerminal: Bool { [.completed, .succeeded, .failed, .cancelled].contains(self) }
}

/// Sanitized lifecycle-only activity representation. Free-form messages and
/// exception text are never read. The current gateway does not yet return it.
struct RelayJobActivityEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date
    let taskLabel: String?

    init?(wire: [String: Any]) {
        guard let rawID = wire["id"] as? String,
              let id = Self.safeIdentifier(rawID),
              let type = wire["type"] as? String,
              let title = Self.labels[type],
              let timestamp = wire["timestamp"] as? String,
              let date = RelayTimestamp.parse(timestamp) else { return nil }
        let taskID = (wire["taskId"] as? String).flatMap(Self.safeIdentifier)
        self.id = id
        self.title = title
        self.date = date
        self.taskLabel = taskID.map { "Task \($0)" }
    }

    private static let labels: [String: String] = [
        "job.created": "Job created", "job.planned": "Plan ready",
        "task.queued": "Task queued", "task.started": "Task started",
        "task.progress": "Task progress updated", "task.completed": "Task completed",
        "task.failed": "Task failed", "task.cancelled": "Task cancelled",
        "job.cancelled": "Job cancelled", "job.completed": "Job completed",
        "job.failed": "Job failed", "review.approved": "Review approved",
        "review.changes_required": "Changes requested"
    ]

    private static func safeIdentifier(_ value: String) -> String? {
        guard value.range(of: "^[A-Za-z0-9_.-]{1,64}$", options: .regularExpression) != nil else { return nil }
        return value
    }

}

private enum RelayTimestamp {
    static func parse(_ value: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

enum RelayJobCancellationError: LocalizedError, Equatable {
    case unsupported
    case unconfirmed

    var errorDescription: String? {
        switch self {
        case .unsupported: "Cancellation is not available through this Master yet."
        case .unconfirmed: "The Master did not confirm cancellation. Refresh and try again."
        }
    }
}

@MainActor
final class RelayJobsStore: ObservableObject {
    typealias CancelOperation = (RelayJob) async throws -> RelayJob

    @Published private(set) var jobs: [RelayJob] = []
    @Published private(set) var cancellingIDs = Set<String>()
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var activities: [String: [RelayJobActivityEvent]] = [:]
    private var refreshing = false
    private let cancelOperation: CancelOperation?

    init(cancelOperation: CancelOperation? = nil) {
        self.cancelOperation = cancelOperation
    }

    func refresh(from master: RemoteMCPClient) async {
        guard !refreshing else { return }
        refreshing = true
        isLoading = jobs.isEmpty && !hasLoaded
        defer { refreshing = false }
        defer { isLoading = false }
        guard master.hasConfiguredAddress && master.hasCredential else {
            hasLoaded = true
            return
        }
        if !master.connected { await master.connect() }
        guard master.connected else {
            hasLoaded = true
            return
        }
        do {
            jobs = try await master.relayJobs()
            hasLoaded = true
        } catch {
            // Preserve the last good snapshot during temporary connection loss.
            hasLoaded = true
        }
    }

    func cancel(_ job: RelayJob) async throws {
        guard job.canCancel, !cancellingIDs.contains(job.id),
              let cancelOperation else { throw RelayJobCancellationError.unsupported }
        cancellingIDs.insert(job.id)
        defer { cancellingIDs.remove(job.id) }
        let response = try await cancelOperation(job)
        guard response.id == job.id, response.lifecycle == .cancelled else {
            throw RelayJobCancellationError.unconfirmed
        }
        jobs.removeAll { $0.id == response.id }
        jobs.append(response)
    }

    func isCancelling(_ job: RelayJob) -> Bool { cancellingIDs.contains(job.id) }
    func canCancel(_ job: RelayJob) -> Bool { job.canCancel && cancelOperation != nil }

    func setActivity(_ events: [RelayJobActivityEvent], for jobID: String) {
        activities[jobID] = events.sorted { $0.date > $1.date }
    }

    func activity(for jobID: String) -> [RelayJobActivityEvent]? { activities[jobID] }

    var ordered: [RelayJob] {
        jobs.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    #if DEBUG
    func seedForUITest() {
        jobs = [
            RelayJob(wire: ["id": "fixture-8", "title": "Running vlog edit",
                            "status": "RUNNING", "updatedAt": "2026-11-08T16:40:00Z",
                            "repository": "lalalic/neo"])!,
            RelayJob(wire: ["id": "fixture-7", "title": "Finished validation",
                            "status": "COMPLETED", "updatedAt": "2026-11-08T16:30:00Z",
                            "repository": "lalalic/neo"])!,
        ]
    }
    #endif
}

struct RelayJobsView: View {
    @ObservedObject var master: RemoteMCPClient
    @StateObject private var store = RelayJobsStore()
    @State private var confirmationJob: RelayJob?
    @State private var failureMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.ordered) { job in
                    NavigationLink(value: job) {
                        RelayJobRow(job: job, reduceMotion: reduceMotion)
                    }
                    .accessibilityIdentifier("neoRelayJobRow-\(job.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if store.canCancel(job) {
                            Button(role: .destructive) { confirmationJob = job } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                            }
                            .disabled(store.isCancelling(job))
                        }
                    }
                }
            }
            .overlay {
                if store.jobs.isEmpty && store.isLoading {
                    ProgressView("Loading Jobs")
                } else if store.jobs.isEmpty {
                    ContentUnavailableView("No recent Jobs", systemImage: "tray",
                                           description: Text("Jobs from your selected Master will appear here."))
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("neoRelayJobsList")
            .refreshable { await store.refresh(from: master) }
            .navigationTitle("Jobs")
            .navigationDestination(for: RelayJob.self) { job in
                RelayJobDetailView(job: store.jobs.first(where: { $0.id == job.id }) ?? job,
                                   store: store, master: master)
            }
            .confirmationDialog(
                "Cancel \(confirmationJob?.displayTitle ?? "Job")?",
                isPresented: Binding(
                    get: { confirmationJob != nil },
                    set: { if !$0 { confirmationJob = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Cancel Job", role: .destructive) {
                    guard let job = confirmationJob else { return }
                    confirmationJob = nil
                    Task {
                        do { try await store.cancel(job) }
                        catch {
                            if let safeError = error as? RelayJobCancellationError {
                                failureMessage = safeError.errorDescription
                            } else {
                                failureMessage = "The Master could not confirm cancellation. Refresh and try again."
                            }
                        }
                    }
                }
                Button("Keep Job", role: .cancel) { confirmationJob = nil }
            } message: {
                Text("This stops the Job through Relay and cannot be undone.")
            }
            .alert("Job not cancelled", isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )) {
                Button("OK", role: .cancel) { failureMessage = nil }
            } message: {
                Text(failureMessage ?? "Could not cancel this Job. Refresh and try again.")
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-neo-jobs-ui-fixture") {
                store.seedForUITest()
                return
            }
            #endif
            while !Task.isCancelled {
                await store.refresh(from: master)
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
            }
        }
    }
}

private struct RelayJobRow: View {
    let job: RelayJob
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: job.lifecycle.symbol)
                .symbolEffect(.pulse, isActive: job.lifecycle.isRunning && !reduceMotion)
                .foregroundStyle(job.lifecycle.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("#\(job.id)")
                    Text(job.statusName)
                    if !job.repository.isEmpty { Text(job.repository).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.displayTitle), \(job.statusName)")
    }
}

private struct RelayJobDetailView: View {
    let job: RelayJob
    @ObservedObject var store: RelayJobsStore
    @ObservedObject var master: RemoteMCPClient

    var body: some View {
        List {
            Section("Status") {
                Label(job.statusName, systemImage: job.lifecycle.symbol)
                    .foregroundStyle(job.lifecycle.tint)
                LabeledContent("Job", value: "#\(job.id)")
                if !job.repository.isEmpty { LabeledContent("Repository", value: job.repository) }
                if let date = RelayTimestamp.parse(job.updatedAt) {
                    LabeledContent("Last updated", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Activity") {
                if let activity = store.activity(for: job.id) {
                    if activity.isEmpty {
                        ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(activity) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title)
                                HStack {
                                    if let taskLabel = event.taskLabel { Text(taskLabel) }
                                    Spacer()
                                    Text(event.date, style: .relative)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Activity not available yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("This Master currently provides Job summaries only. Activity will appear when the gateway supports it.")
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(job.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(from: master) }
    }
}
