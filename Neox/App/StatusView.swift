import Photos
import SwiftUI

/// Status screen — the only human-facing surface. Exists to show the agent
/// where to connect, and to grant Photos permission once.
struct StatusView: View {
    @EnvironmentObject private var bridge: BridgeServer

    var body: some View {
        NavigationStack {
            List {
                Section("MCP Server") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(stateColor)
                            .frame(width: 10, height: 10)
                        Text(stateText)
                            .font(.headline)
                    }
                    LabeledContent("Endpoint", value: bridge.mcpURL)
                    LabeledContent("Bonjour", value: "neox._mcp._tcp")
                    LabeledContent("LAN IP", value: BridgeServer.lanIPAddress() ?? "unavailable")
                }

                Section("Photo Library") {
                    LabeledContent("Access", value: authText)
                    if bridge.photosStatus == .notDetermined {
                        Button("Allow Access") { bridge.requestPhotosAccess() }
                    }
                }

                Section("Tools") {
                    ForEach(["photos_search", "photos_export", "device_info"], id: \.self) { tool in
                        Label(tool, systemImage: "wrench.and.screwdriver")
                            .font(.callout)
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

                Section {
                    Button("Clear Exported Files", role: .destructive) { bridge.clearExports() }
                } footer: {
                    Text("Exported media lives in the app's caches directory and is removed by iOS under storage pressure. Keep the app foregrounded for reliable serving.")
                }
            }
            .navigationTitle("Neox")
        }
        .onAppear { bridge.ensureRunning() }
    }

    private var stateText: String {
        switch bridge.state {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .running: "Running"
        case .failed(let error): "Failed — \(error)"
        }
    }

    private var stateColor: Color {
        switch bridge.state {
        case .running: .green
        case .failed: .red
        default: .orange
        }
    }

    private var authText: String {
        switch bridge.photosStatus {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Denied — enable in Settings"
        case .authorized: "Authorized"
        case .limited: "Limited selection"
        @unknown default: "Unknown"
        }
    }
}
