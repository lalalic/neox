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

/// Canonical Relay events are credential-redacted by the authenticated Gateway.
struct RelayJobActivityEvent: Identifiable, Equatable {
    let id: String
    let jobID: String
    let type: String
    let title: String
    let content: String?
    let date: Date
    let taskID: String?
    let taskLabel: String?
    let details: String?

    init?(wire: [String: Any]) {
        guard let rawID = wire["event_id"] as? String,
              let jobID = wire["job_id"] as? String,
              !jobID.isEmpty,
              let id = Self.safeIdentifier(rawID),
              let type = wire["type"] as? String,
              !type.isEmpty, type.count <= 128,
              let timestamp = wire["timestamp"] as? String,
              let date = RelayTimestamp.parse(timestamp) else { return nil }
        self.jobID = jobID
        self.id = id
        self.type = type
        self.title = Self.labels[type] ?? type
        let message = (wire["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalMessage: String
        if let message, message == type, type.hasPrefix("task.") {
            let data = wire["data"] as? [String: Any] ?? [:]
            canonicalMessage = ["reason", "evidence", "phase"].compactMap { key in
                (data[key] as? String).flatMap(Self.cleanedMessage)
            }.first ?? message
        } else {
            canonicalMessage = message.flatMap(Self.cleanedMessage)
                ?? Self.dashboardFallback(data: wire["data"]) ?? "Event received"
        }
        self.content = Self.cleanedMessage(canonicalMessage).map(Self.abbreviateCommitSHAs)
        self.date = date
        self.taskID = (wire["task_id"] as? String).flatMap(Self.safeIdentifier)
        self.taskLabel = self.taskID.map { "Task \($0)" }
        let detailFields = wire.filter { ["level", "status", "message", "data"].contains($0.key) }
        if !detailFields.isEmpty,
           let bytes = try? JSONSerialization.data(withJSONObject: detailFields, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: bytes, encoding: .utf8) {
            self.details = text
        } else {
            self.details = nil
        }
    }

    private static func cleanedMessage(_ value: String) -> String? {
        let cleaned = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Compact timeline text only; preserve event identities and full audit details.
    private static func abbreviateCommitSHAs(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "(?<![0-9A-Za-z])(?:[0-9a-fA-F]{64}|[0-9a-fA-F]{40})(?![0-9A-Za-z])") else { return text }
        var result = text
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: result[range].suffix(6))
        }
        return result
    }

    private static func dashboardFallback(data: Any?) -> String? {
        guard let data = data as? [String: Any] else { return nil }
        let phase = data["phase"] as? String
        let evidence = data["evidence"] as? String
        let next = data["next"] as? String
        let parts = [phase, evidence.map { "Evidence: \($0)" }, next.map { "Next: \($0)" }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let labels: [String: String] = [
        "job.created": "Job created", "job.planned": "Plan ready",
        "task.queued": "Task queued", "task.started": "Task started",
        "task.progress": "Task progress updated", "task.completed": "Task completed",
        "task.failed": "Task failed", "task.cancelled": "Task cancelled",
        "task.blocked": "Task blocked", "task.unblocked": "Task unblocked",
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
        case "job.blocked", "review.blocked", "task.blocked": "hand.raised.circle"
        case "task.unblocked": "arrow.uturn.forward.circle"
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

    static func canonicalHistory(_ rows: [[String: Any]], jobID: String) -> [RelayJobActivityEvent]? {
        var unique: [String: (Int, RelayJobActivityEvent)] = [:]
        for (index, row) in rows.enumerated() {
            guard let eventID = row["event_id"] as? String,
                  let type = row["type"] as? String,
                  let timestamp = row["timestamp"] as? String,
                  let eventJob = row["job_id"] as? String,
                  Self.safeIdentifier(eventID) != nil, !type.isEmpty, RelayTimestamp.parse(timestamp) != nil else { continue }
            guard eventJob == jobID else { return nil }
            guard let event = RelayJobActivityEvent(wire: row) else { continue }
            if let previous = unique[eventID], previous.1.date >= event.date { continue }
            unique[eventID] = (index, event)
        }
        return Array(unique.values.sorted {
            if $0.1.date != $1.1.date { return $0.1.date > $1.1.date }
            return $0.0 < $1.0
        }.prefix(60).map(\.1))
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

private enum RelayJobsFetchError: Error { case notConnected }

/// One server-side page, with an authoritative offset over the unfiltered Relay inventory.
struct RelayJobsPage {
    static let pageSize = 20
    let jobs: [RelayJob]
    let total: Int
    let nextOffset: Int
    let hasMore: Bool
}

@MainActor
final class RelayJobsStore: ObservableObject {
    typealias CancelOperation = (RelayJob) async throws -> RelayJob
    typealias PageOperation = (Int, Int) async throws -> RelayJobsPage
    typealias ActivityOperation = (RelayJob) async throws -> [RelayJobActivityEvent]
    typealias TaskTitlesOperation = (RelayJob) async throws -> [String: String]

    @Published private(set) var jobs: [RelayJob] = []
    @Published private(set) var cancellingIDs = Set<String>()
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var total = 0
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var activities: [String: [RelayJobActivityEvent]] = [:]
    @Published private var activityTaskTitles: [String: [String: String]] = [:]
    @Published private(set) var liveRevision = 0
    @Published private(set) var activityLoadingIDs = Set<String>()
    @Published private(set) var activityErrors: [String: String] = [:]
    private var refreshing = false
    private var activityRefreshPendingIDs = Set<String>()
    private var nextOffset = 0
    private let cancelOperation: CancelOperation?
    private let pageOperation: PageOperation?
    private let activityOperation: ActivityOperation?
    private let taskTitlesOperation: TaskTitlesOperation?

    private func key(_ job: RelayJob) -> String { "\(job.repository)#\(job.id)" }

    init(cancelOperation: CancelOperation? = nil, pageOperation: PageOperation? = nil,
         activityOperation: ActivityOperation? = nil, taskTitlesOperation: TaskTitlesOperation? = nil) {
        self.cancelOperation = cancelOperation
        self.pageOperation = pageOperation
        self.activityOperation = activityOperation
        self.taskTitlesOperation = taskTitlesOperation
    }

    private func fetchPage(from master: RemoteMCPClient, offset: Int) async throws -> RelayJobsPage {
        if let pageOperation { return try await pageOperation(offset, RelayJobsPage.pageSize) }
        guard master.hasConfiguredAddress && master.hasCredential else {
            throw RelayJobsFetchError.notConnected
        }
        // Unified Jobs REST is independently Bearer-authenticated. Do not
        // block its request on the legacy MCP tool-list connection: after
        // cutover that MCP provider is deliberately retired.
        return try await master.relayJobs(offset: offset)
    }

    func refresh(from master: RemoteMCPClient) async {
        guard !refreshing && !isLoadingMore else { return }
        refreshing = true
        isLoading = jobs.isEmpty
        defer { refreshing = false; isLoading = false; hasLoaded = true }
        do {
            applyPage(try await fetchPage(from: master, offset: 0), reset: true)
            loadError = nil
        } catch {
            // A failed first page is not proof of an empty Relay inventory.
            // An isolated test bundle has its own credentials and preferences.
            loadError = !master.hasConfiguredAddress || !master.hasCredential
                ? "Connect to Neo Master in Connector to load Jobs."
                : "Cannot load Jobs from Neo Master. Check the connection and retry."
            // Retain the visible page during temporary network failures.
        }
    }

    func loadMore(from master: RemoteMCPClient) async {
        guard hasLoaded && hasMore && !refreshing && !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetchPage(from: master, offset: nextOffset)
            applyPage(page, reset: false)
        } catch {
            // Preserve the accumulated rows and offset; a later bottom scroll can retry.
        }
    }

    private func applyPage(_ page: RelayJobsPage, reset: Bool) {
        let visible = page.jobs.filter { $0.lifecycle != .cancelled }
        if reset {
            jobs = visible
        } else {
            var merged = jobs
            for cancelled in page.jobs where cancelled.lifecycle == .cancelled {
                merged.removeAll { $0.id == cancelled.id && $0.repository == cancelled.repository }
            }
            for item in visible {
                if let index = merged.firstIndex(where: { $0.id == item.id && $0.repository == item.repository }) {
                    merged[index] = item
                } else {
                    merged.append(item)
                }
            }
            jobs = merged
        }
        total = page.total
        // Never advance backwards or infinitely re-fetch an empty page.
        let advanced = reset || page.nextOffset > nextOffset
        nextOffset = reset ? page.nextOffset : max(page.nextOffset, nextOffset)
        hasMore = advanced && page.hasMore
    }

    func applySnapshot(_ snapshot: [RelayJob]) {
        jobs = snapshot.filter { $0.lifecycle != .cancelled }
        hasMore = false
        nextOffset = snapshot.count
        total = snapshot.count
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
    }

    func isCancelling(_ job: RelayJob) -> Bool { cancellingIDs.contains(key(job)) }
    func canCancel(_ job: RelayJob) -> Bool { job.canCancel && cancelOperation != nil }

    func refreshActivity(for job: RelayJob, from master: RemoteMCPClient) async {
        let identity = key(job)
        guard !activityLoadingIDs.contains(identity) else {
            activityRefreshPendingIDs.insert(identity)
            return
        }
        activityLoadingIDs.insert(identity)
        defer { activityLoadingIDs.remove(identity) }
        guard activityOperation != nil || (master.hasCredential && master.hasConfiguredAddress) else {
            activityErrors[identity] = "Connect to Neo Master to load Activity."
            return
        }
        // Keep canonical history independent of the sanitized task-title lookup.
        repeat {
            activityRefreshPendingIDs.remove(identity)
            do {
                let result: [RelayJobActivityEvent]
                if let activityOperation { result = try await activityOperation(job) }
                else { result = try await master.relayJobActivity(job) }
                activities[identity] = result
                activityErrors.removeValue(forKey: identity)
                if result.contains(where: { $0.taskID != nil }) {
                    if let taskTitlesOperation {
                        if let titles = try? await taskTitlesOperation(job) { activityTaskTitles[identity] = titles }
                    } else if activityOperation == nil {
                        if let titles = try? await master.relayJobTasks(job) { activityTaskTitles[identity] = titles }
                    }
                }
            } catch {
                activityErrors[identity] = "Unable to load Activity from Neo Master. Retry."
            }
        } while activityRefreshPendingIDs.remove(identity) != nil
    }

    func isActivityLoading(_ job: RelayJob) -> Bool {
        activityLoadingIDs.contains(key(job))
    }

    func activityError(for job: RelayJob) -> String? {
        activityErrors[key(job)]
    }

    func receiveLiveChange() {
        liveRevision &+= 1
    }

    func setActivity(_ events: [RelayJobActivityEvent], for job: RelayJob) {
        activities[key(job)] = events
    }

    func activity(for job: RelayJob) -> [RelayJobActivityEvent]? { activities[key(job)] }

    func activityDescription(for event: RelayJobActivityEvent, job: RelayJob) -> String {
        event.content ?? event.title
    }

    func activityTaskCaption(for event: RelayJobActivityEvent, job: RelayJob) -> String? {
        guard let id = event.taskID else { return nil }
        guard let title = activityTaskTitles[key(job)]?[id], !title.isEmpty else { return id }
        return "\(id): \(title)"
    }

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
        let running = jobs[0]
        let fixture: [String: Any] = [
            "event_id": "fixture-progress", "job_id": running.id, "type": "task.progress",
            "timestamp": "2026-11-17T11:12:00Z", "task_id": "1943",
            "message": "Verified the model orientation using the front photo."
        ]
        if let event = RelayJobActivityEvent(wire: fixture) {
            setActivity([event], for: running)
            activityTaskTitles[key(running)] = ["1943": "Verify model orientation"]
        }
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-neo-jobs-pagination-fixture") {
            _store = StateObject(wrappedValue: RelayJobsStore(pageOperation: { offset, limit in
                let rows = (1...47).compactMap { id in
                    RelayJob(wire: ["id": String(id), "title": "Paginated Job \(id)",
                                    "repository": "vlog", "status": "COMPLETED",
                                    "createdAt": "2026-11-12T10:00:00Z",
                                    "updatedAt": "2026-11-12T10:00:00Z"])
                }
                let page = Array(rows.dropFirst(offset).prefix(limit))
                let next = offset + page.count
                return RelayJobsPage(jobs: page, total: rows.count,
                                     nextOffset: next, hasMore: next < rows.count)
            }))
            return
        }
        #endif
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
                if store.hasMore || store.isLoadingMore {
                    HStack {
                        Spacer()
                        if store.isLoadingMore {
                            ProgressView("Loading 20 more Jobs")
                        } else {
                            Text("\(store.jobs.count) / \(store.total) · Swipe up for 20 more")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityIdentifier("neoRelayJobsLoadMore")
                    .onAppear {
                        Task { await store.loadMore(from: master) }
                    }
                }
            }
            .overlay {
                if store.jobs.isEmpty && store.isLoading {
                    ProgressView("Loading Jobs")
                } else if store.jobs.isEmpty, let error = store.loadError {
                    VStack(spacing: 12) {
                        Label("Jobs unavailable", systemImage: "wifi.exclamationmark")
                            .font(.headline)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry Jobs") {
                            Task { await store.refresh(from: master) }
                        }
                        .accessibilityIdentifier("neoRelayJobsRetry")
                    }
                    .padding()
                } else if store.jobs.isEmpty {
                    ContentUnavailableView("No recent Jobs", systemImage: "tray",
                                           description: Text("Jobs from your selected Master will appear here."))
                }
            }
            // Do not put an identifier on the whole List: on iOS 26 it
            // overrides individual row and Retry button accessibility IDs.
            .refreshable { await store.refresh(from: master) }
            .listStyle(.plain)
            .navigationDestination(for: RelayJob.self) { job in
                RelayJobDetailView(job: job, store: store, master: master)
                    .id("\(job.repository)#\(job.id)")
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
        .task(id: master.endpoint) {
            // The user may pair/select Neo Master after Jobs was initially
            // created by TabView. Always refresh on a selected Master change.
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-neo-jobs-ui-fixture") {
                store.seedForUITest()
                return
            }
            #endif
            await store.refresh(from: master)
            guard master.hasConfiguredAddress && master.hasCredential else { return }
            // Subscribe to the authenticated, redacted Relay change stream.
            // Never infer new state from SSE payloads; re-fetch durable REST.
            while !Task.isCancelled {
                do {
                    let rest = try master.unifiedGatewayREST()
                    try await rest.relayChanges(onConnected: {
                        store.receiveLiveChange()
                    }, onChange: {
                        await store.refresh(from: master)
                        store.receiveLiveChange()
                    })
                } catch {
                    // Older Masters may not yet expose this route. Keep the
                    // loaded Jobs usable and retry without switching identity.
                }
                if Task.isCancelled { return }
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                // A new authenticated stream connection triggers a history
                // refresh in an open detail so changes during the gap converge.
            }
        }
        .onChange(of: master.connected) { _, isConnected in
            // The same URL may be re-paired later with a valid credential.
            // Jobs REST also works without this MCP connection, but a new
            // successful pairing should restore the owner-visible list.
            if isConnected { Task { await store.refresh(from: master) } }
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
    @State private var metadataExpanded = false

    var body: some View {
        // NavigationLink captures a snapshot; @ObservedObject ensures the latest
        // authoritative status is reflected when the Job list refreshes.
        let current = store.currentJob(matching: job)
        return List {
            Section {
                Button {
                    metadataExpanded.toggle()
                } label: {
                    Label(metadataExpanded ? "Hide job details" : "Show job details",
                          systemImage: metadataExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows or hides the job, repository, and timestamps")
                .accessibilityIdentifier("neoRelayJobMetadataToggle")
                if metadataExpanded {
                    LabeledContent("Job", value: "#\(current.id)")
                    if !current.repository.isEmpty { LabeledContent("Repository", value: current.repository) }
                    LabeledContent("Created", value: RelayTimestamp.creationDetail(current.createdAt) ?? "Date unavailable")
                    if let date = RelayTimestamp.parse(current.updatedAt) {
                        LabeledContent("Last updated", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            Section {
                if store.activity(for: job) != nil, let error = store.activityError(for: job) {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry Activity") {
                        Task { await store.refreshActivity(for: job, from: master) }
                    }
                    .accessibilityIdentifier("neoRelayActivityRetry")
                }
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
                                    Text(store.activityDescription(for: event, job: job))
                                        .lineLimit(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 6) {
                                        if let caption = store.activityTaskCaption(for: event, job: job) {
                                            Text(caption).lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        Text(RelayTimestamp.activityDisplay(event.date))
                                            .lineLimit(1)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if let details = event.details {
                                        DisclosureGroup("Event details") {
                                            Text(details)
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                } else if !store.isActivityLoading(job), let error = store.activityError(for: job) {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "Activity unavailable",
                            systemImage: "wifi.exclamationmark",
                            description: Text(error)
                        )
                        Button("Retry Activity") {
                            Task { await store.refreshActivity(for: job, from: master) }
                        }
                        .accessibilityIdentifier("neoRelayActivityRetry")
                    }
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
            await store.refreshActivity(for: job, from: master)
        }
        .onChange(of: store.liveRevision) { _, _ in
            Task { await store.refreshActivity(for: job, from: master) }
        }
    }
}
