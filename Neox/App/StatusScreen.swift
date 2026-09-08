import Photos
import SwiftUI

/// Status screen — the only human-facing surface. Shows where to connect,
/// what the server is doing, and grants Photos permission once.
struct StatusView: View {
    @EnvironmentObject private var bridge: ServerController

    var body: some View {
        VStack(spacing: 0) {
            // Top: running indicator + endpoint
            HStack(spacing: 10) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 14, height: 14)
                Text(bridge.mcpURL)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)

            Divider()

            // Requests: tool list first, then every tool call
            ListView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Foot buttons
            HStack(spacing: 12) {
                if bridge.photosStatus != .authorized && bridge.photosStatus != .limited {
                    Button { Task { await bridge.requestPhotosAccess() } } label: {
                        Label("Access Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) { bridge.clearExports() } label: {
                    Label("Clear Exports", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
        }
        .background(Color(.systemBackground))
        .onAppear { bridge.ensureRunning() }
    }

    private var ListView: some View {
        List {
            Section("Siri / Shortcuts") {
                Text("“Hey Siri, create a vlog with Neox”")
                    .font(.subheadline)
                Text(AgentHandoff.message(instruction: AgentHandoff.defaultInstruction,
                                          mcpURL: bridge.mcpURL))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Tools") {
                ForEach(bridge.registeredTools, id: \.self) { tool in
                    Text(tool)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
            }

            Section("Requests") {
                if bridge.logLines.isEmpty {
                    Text("No requests yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(bridge.logLines.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var stateColor: Color {
        switch bridge.state {
        case .running: .green
        case .failed: .red
        default: .orange
        }
    }
}
