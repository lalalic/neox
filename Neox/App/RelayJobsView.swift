import SwiftUI

/// Display-only Relay job metadata. Prompts, objectives and paths are ignored.
struct RelayJob: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let repository: String
    let status: String
    let updatedAt: String
    /// Durable Relay creation time, never inferred from update time.
    let createdAt: String
    /// Only the authenticated gateway may advertise this capability.
    /// The actual operation rechecks the durable Job state (no PR is required).
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
        self.createdAt = Self.clean(wire["createdAt"] as? String ?? "", limit: 40) ?? ""
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
        lifecycle.isActive
    }
    var displayTitle: String { title.isEmpty ? "Job \(id)" : title }

    /// Requires explicit gateway capability and a nonterminal Relay state.
    /// Older gateways omit this property, which safely hides the action.
    var canCancel: Bool {
        gatewayAllowsCancellation && lifecycle.isActive
    }
}

enum RelayJobLifecycle: Equatable {
    case planning, queued, active, idle, waiting, running, reviewing, mergePending, paused, blocked
    case merged, completed, succeeded, failed, cancelled, unknown

    init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "PLANNING": self = .planning
        case "QUEUED", "DRAFT": self = .queued
        case "ACTIVE": self = .active
        case "IDLE": self = .idle
        case "WAITING": self = .waiting
        case "RUNNING": self = .running
        case "REVIEWING": self = .reviewing
        case "MERGE_PENDING": self = .mergePending
        case "PAUSED", "AWAITING_DECISION": self = .paused
        case "BLOCKED": self = .blocked
        case "MERGED": self = .merged
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
        case .idle: "Idle"
        case .waiting: "Waiting"
        case .running: "Running"
        case .reviewing: "Reviewing"
        case .mergePending: "Merge pending"
        case .paused: "Paused"
        case .blocked: "Blocked"
        case .merged: "Merged"
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
        case .idle, .waiting: "hourglass"
        case .reviewing: "eye"
        case .mergePending: "arrow.triangle.merge"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .paused: "pause.circle"
        case .blocked: "hand.raised.circle"
        case .merged, .completed, .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .planning, .queued, .active, .running: .accentColor
        case .reviewing, .mergePending: .accentColor
        case .idle, .waiting, .paused, .blocked, .unknown: .secondary
        case .merged, .completed, .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    var isActive: Bool {
        [.planning, .queued, .active, .idle, .waiting, .running, .reviewing, .mergePending, .paused, .blocked].contains(self)
    }
    var isRunning: Bool { self == .running }
    var isTerminal: Bool { [.merged, .completed, .succeeded, .failed, .cancelled].contains(self) }
}

/// Sanitized lifecycle-only activity representation. Free-form messages and
/// exception text are never read.
struct RelayJobActivityEvent: Identifiable, Equatable {
    let id: String
    let type: String
    let title: String
    let date: Date
    let taskLabel: String?

    init?(wire: [String: Any], fallbackID: String? = nil) {
        guard let rawID = (wire["id"] as? String) ?? fallbackID,
              let id = Self.safeIdentifier(rawID),
              let type = wire["type"] as? String,
              let title = Self.labels[type],
              let timestamp = wire["timestamp"] as? String,
              let date = RelayTimestamp.parse(timestamp) else { return nil }
        let taskID = (wire["taskId"] as? String).flatMap(Self.safeIdentifier)
        self.id = id
        self.type = type
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
        "job.failed": "Job failed", "job.blocked": "Job blocked",
        "review.approved": "Review approved",
        "review.changes_required": "Changes requested",
        "planner.started": "Planning started", "planner.completed": "Planning completed",
        "job.runtime_status.changed": "Job status changed",
        "task.created": "Task created", "task.dispatch": "Task dispatched",
        "task.process.launched": "Task running", "task.release": "Task released",
        "task.succeeded": "Task completed", "review.created": "Review requested",
        "review.requested": "Review requested", "review.started": "Review running",
        "review.blocked": "Review blocked"
    ]

    /// Decorative presentation selected from the sanitized event type only.
    var symbol: String {
        switch type {
        case "job.created", "task.created": "plus.circle"
        case "job.planned", "planner.completed": "doc.text"
        case "task.queued": "clock"
        case "task.started", "task.dispatch", "task.process.launched", "task.release": "play.circle"
        case "task.progress", "job.runtime_status.changed": "arrow.trianglehead.2.clockwise.rotate.90"
        case "task.completed", "task.succeeded", "job.completed": "checkmark.circle"
        case "task.failed", "job.failed": "exclamationmark.triangle"
        case "task.cancelled", "job.cancelled": "xmark.circle"
        case "job.blocked", "review.blocked": "hand.raised.circle"
        case "review.approved": "checkmark.seal"
        case "review.changes_required": "arrow.uturn.backward.circle"
        case "review.created", "review.requested", "review.started": "eye"
        case "planner.started": "wand.and.stars"
        default: "circle"
        }
    }

    private static func safeIdentifier(_ value: String) -> String? {
        guard value.range(of: "^[A-Za-z0-9_.-]{1,64}$", options: .regularExpression) != nil else { return nil }
        return value
    }

}

enum RelayTimestamp {
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

    static func creationDisplay(
        _ value: String,
        referenceDate: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let date = parse(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let includeYear = calendar.component(.year, from: date) != calendar.component(.year, from: referenceDate)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(includeYear ? "MMM d yyyy h:mm a" : "MMM d h:mm a")
        return formatter.string(from: date)
    }

    static func creationDetail(
        _ value: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let date = parse(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d yyyy h:mm a")
        return formatter.string(from: date)
    }

    static func activityDisplay(
        _ date: Date,
        referenceDate: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(date, inSameDayAs: referenceDate)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: referenceDate)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(
            sameDay ? "h:mm a" : (sameYear ? "MMM d h:mm a" : "MMM d yyyy h:mm a")
        )
        return formatter.string(from: date)
    }

    static func activityDisplay(
        _ value: String,
        referenceDate: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let date = parse(value) else { return nil }
        return activityDisplay(date, referenceDate: referenceDate, locale: locale, timeZone: timeZone)
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

    private func key(_ job: RelayJob) -> String { "\(job.repository)#\(job.id)" }

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
            applySnapshot(try await master.relayJobs())
            hasLoaded = true
        } catch {
            // Preserve the last good snapshot during temporary connection loss.
            hasLoaded = true
        }
    }

    func applySnapshot(_ snapshot: [RelayJob]) {
        jobs = snapshot
    }

    func currentJob(matching job: RelayJob) -> RelayJob {
        jobs.first(where: { $0.id == job.id && $0.repository == job.repository }) ?? job
    }

    func cancel(_ job: RelayJob) async throws {
        guard job.canCancel, !cancellingIDs.contains(key(job)),
              let cancelOperation else { throw RelayJobCancellationError.unsupported }
        cancellingIDs.insert(key(job))
        defer { cancellingIDs.remove(key(job)) }
        let response = try await cancelOperation(job)
        guard response.id == job.id, response.repository == job.repository,
              response.lifecycle == .cancelled else {
            throw RelayJobCancellationError.unconfirmed
        }
        jobs.removeAll { $0.id == response.id && $0.repository == response.repository }
        jobs.append(response)
    }

    func isCancelling(_ job: RelayJob) -> Bool { cancellingIDs.contains(key(job)) }
    func canCancel(_ job: RelayJob) -> Bool { job.canCancel && cancelOperation != nil }

    func refreshActivity(for job: RelayJob, from master: RemoteMCPClient) async {
        if !master.connected { await master.connect() }
        guard master.connected else { return }
        do {
            let rows = try await master.relayJobActivity(job)
            activities[key(job)] = rows.sorted { $0.date > $1.date }
        } catch {
            // Preserve the last authoritative history if the Master is unavailable.
        }
    }

    func setActivity(_ events: [RelayJobActivityEvent], for job: RelayJob) {
        activities[key(job)] = events.sorted { $0.date > $1.date }
    }

    func activity(for job: RelayJob) -> [RelayJobActivityEvent]? { activities[key(job)] }

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
            RelayJob(wire: ["id": "fixture-6", "title": "Waiting for event",
                            "status": "WAITING", "updatedAt": "2026-11-08T16:35:00Z",
                            "repository": "local/vlog"])!,
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

    init(master: RemoteMCPClient) {
        self.master = master
        _store = StateObject(wrappedValue: RelayJobsStore(cancelOperation: { job in
            try await master.cancelRelayJob(job)
        }))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.ordered) { job in
                    NavigationLink(value: job) {
                        RelayJobRow(job: job, reduceMotion: reduceMotion)
                    }
                    .accessibilityIdentifier("neoRelayJobRow-\(job.id)")
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
            .accessibilityIdentifier("neoRelayJobsList")
            .refreshable { await store.refresh(from: master) }
            .listStyle(.plain)
            .navigationDestination(for: RelayJob.self) { job in
                RelayJobDetailView(job: job, store: store, master: master)
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
                Text("Created \(RelayTimestamp.creationDisplay(job.createdAt) ?? "Date unavailable")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        // NavigationLink captures a snapshot; @ObservedObject ensures the latest
        // authoritative status is reflected when the Job list refreshes.
        let current = store.currentJob(matching: job)
        return List {
            Section("Status") {
                Label(current.statusName, systemImage: current.lifecycle.symbol)
                    .foregroundStyle(current.lifecycle.tint)
                LabeledContent("Job", value: "#\(current.id)")
                if !current.repository.isEmpty { LabeledContent("Repository", value: current.repository) }
                LabeledContent(
                    "Created",
                    value: RelayTimestamp.creationDetail(current.createdAt) ?? "Date unavailable"
                )
                if let date = RelayTimestamp.parse(current.updatedAt) {
                    LabeledContent("Last updated", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Activity") {
                if let activity = store.activity(for: job) {
                    if activity.isEmpty {
                        ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(activity) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: event.symbol)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title)
                                    HStack {
                                        if let taskLabel = event.taskLabel { Text(taskLabel) }
                                        Spacer()
                                        Text(RelayTimestamp.activityDisplay(event.date))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
        .listStyle(.plain)
        .navigationTitle(job.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(from: master)
            await store.refreshActivity(for: job, from: master)
        }
        .task(id: "\(job.repository)/\(job.id)") {
            while !Task.isCancelled {
                await store.refreshActivity(for: job, from: master)
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
            }
        }
    }
}
