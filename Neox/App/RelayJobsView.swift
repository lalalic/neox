import SwiftUI

/// Display-only Relay job metadata. No prompts, objectives or local paths.
struct RelayJob: Identifiable, Equatable {
    let id: String
    let title: String
    let repository: String
    let status: String
    let updatedAt: String

    init?(wire: [String: Any]) {
        guard let id = wire["id"] as? String, !id.isEmpty,
              let status = wire["status"] as? String, !status.isEmpty else { return nil }
        self.id = id
        self.title = wire["title"] as? String ?? ""
        self.repository = wire["repository"] as? String ?? ""
        self.status = status
        self.updatedAt = wire["updatedAt"] as? String ?? ""
    }

    var statusName: String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var isActive: Bool {
        !["COMPLETED", "CANCELLED", "FAILED", "SUCCEEDED"].contains(status.uppercased())
    }

    var displayTitle: String {
        title.isEmpty ? "Job \(id)" : title
    }
}

@MainActor
final class RelayJobsStore: ObservableObject {
    @Published private(set) var jobs: [RelayJob] = []
    private var refreshing = false

    func refresh(from master: RemoteMCPClient) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard master.hasConfiguredAddress && master.hasCredential else { return }
        if !master.connected { await master.connect() }
        guard master.connected else { return }
        do {
            jobs = try await master.relayJobs()
        } catch {
            // Keep the last snapshot and reconnect automatically. No error UI.
        }
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
        ]
    }
    #endif
}

struct RelayJobsView: View {
    @ObservedObject var master: RemoteMCPClient
    @StateObject private var store = RelayJobsStore()

    var body: some View {
        List {
            ForEach(store.ordered) { job in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: job.isActive ? "circle.dotted.circle" : "checkmark.circle")
                        .foregroundStyle(job.isActive ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
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
                .accessibilityIdentifier("neoRelayJobRow")
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("neoRelayJobsList")
        .refreshable { await store.refresh(from: master) }
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
