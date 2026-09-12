import ActivityKit
import Foundation

@MainActor
final class NeoxLiveActivityManager {
    static let shared = NeoxLiveActivityManager()

    private struct TaskInfo {
        let title: String
        let kind: NeoxActivityKind
        let status: NeoxActivityStatus
        let progress: Double?
    }

    private struct ActivityBox: @unchecked Sendable {
        let value: Activity<NeoxActivityAttributes>
    }

    // ActivityKit's async methods are nonisolated; this reference is only
    // touched by this manager's main-actor methods and their update tasks.
    nonisolated(unsafe) private var activity: Activity<NeoxActivityAttributes>?
    private var tasks: [UUID: TaskInfo] = [:]
    private var serverOnline = false

    private init() { restoreExistingActivity() }

    func setServerOnline(_ online: Bool) {
        serverOnline = online
        sync()
    }

    func start(id: UUID = UUID(), title: String, kind: NeoxActivityKind = .other,
               status: NeoxActivityStatus = .running, progress: Double? = nil) {
        tasks[id] = TaskInfo(title: title, kind: kind, status: status, progress: progress)
        sync()
    }

    func update(id: UUID, title: String? = nil, kind: NeoxActivityKind? = nil,
                status: NeoxActivityStatus? = nil, progress: Double? = nil) {
        guard let current = tasks[id] else { return }
        tasks[id] = TaskInfo(title: title ?? current.title, kind: kind ?? current.kind,
                             status: status ?? current.status, progress: progress ?? current.progress)
        sync()
    }

    func end(id: UUID) {
        tasks.removeValue(forKey: id)
        sync()
    }

    func restoreExistingActivity() {
        activity = Activity<NeoxActivityAttributes>.activities.first
    }

    private func sync() {
        guard !tasks.isEmpty || serverOnline else {
            guard activity != nil else { return }
            Task { @MainActor [weak self] in
                guard let current = self?.activity else { return }
                let box = ActivityBox(value: current)
                await Self.end(box)
            }
            self.activity = nil
            return
        }

        let primary = tasks.values.first
        let state = NeoxActivityAttributes.ContentState(
            activeTaskCount: tasks.count,
            status: tasks.isEmpty ? .waiting : (tasks.count == 1 ? primary?.status ?? .running : .running),
            title: tasks.isEmpty ? "MCP server online" : (tasks.count == 1 ? primary?.title : "Processing Neox work"),
            progress: tasks.count == 1 ? primary?.progress ?? nil : nil,
            activityKind: tasks.isEmpty ? .other : (tasks.count == 1 ? primary?.kind : .other),
            updatedAt: Date()
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        if activity != nil {
            Task { @MainActor [weak self] in
                guard let current = self?.activity else { return }
                let box = ActivityBox(value: current)
                await Self.update(box, content: content)
            }
        } else {
            do {
                activity = try Activity.request(
                    attributes: NeoxActivityAttributes(instanceID: UUID().uuidString),
                    content: content, pushType: nil
                )
            } catch {
                // Optional UI: the MCP bridge remains usable if ActivityKit is unavailable.
            }
        }
    }

    private nonisolated static func end(_ box: ActivityBox) async {
        await box.value.end(nil, dismissalPolicy: .immediate)
    }

    private nonisolated static func update(_ box: ActivityBox, content: ActivityContent<NeoxActivityAttributes.ContentState>) async {
        await box.value.update(content)
    }
}
