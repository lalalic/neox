import SwiftUI

/// Read-only view showing a wired project's WeChat conversation status and history.
struct WeChatProjectStatusView: View {
    let projectId: String
    @ObservedObject var weChatService: WeChatService
    let router: WeChatMessageRouter?
    let sessionState: String

    var body: some View {
        List {
            // Session status
            Section("Session") {
                HStack {
                    Text("State")
                    Spacer()
                    Text(sessionState)
                        .font(.footnote.monospaced())
                        .foregroundStyle(stateColor)
                }

                if let binding = weChatService.getBindings(for: projectId).contacts.first {
                    HStack {
                        Text("Wired To")
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: binding.isRoom ? "person.3.fill" : "person.circle.fill")
                                .font(.caption)
                            Text(binding.name)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // Recent history
            if let history = router?.recentHistory(for: projectId, limit: 50), !history.isEmpty {
                Section("Conversation (\(history.count) messages)") {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.sender)
                                    .font(.caption.bold())
                                    .foregroundStyle(weightColor(entry.weight))
                                Text("w:\(entry.weight)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text(entry.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.text)
                                .font(.subheadline)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Section("Conversation") {
                    Text("No messages yet")
                        .foregroundStyle(.secondary)
                }
            }

            // Response log
            if let log = router?.responseLog, !log.isEmpty {
                Section("Response Log") {
                    ForEach(log, id: \.self) { entry in
                        Text(entry)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle(projectId)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var stateColor: Color {
        switch sessionState {
        case "idle": return .green
        case "working": return .blue
        case "waiting_for_answers", "waiting_for_user": return .orange
        case "error": return .red
        default: return .secondary
        }
    }

    private func weightColor(_ weight: Int) -> Color {
        if weight >= 100 { return .blue }
        if weight >= 50 { return .primary }
        if weight >= 20 { return .secondary }
        return .gray
    }
}
