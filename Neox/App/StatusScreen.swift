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
            // Most-live information first.
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

            // Discovered desktop bridges — the desktop half of the handoff
            // pair, codename "Neoy". Tap to select the preferred one; the
            // intent hands off there.
            Section {
                DisclosureGroup("Neoy: \(bridge.discoveredBridges.count) discovered") {
                    ForEach(bridge.discoveredBridges) { entry in
                        Button {
                            bridge.preferredBridge = entry.name
                        } label: {
                            HStack {
                                Image(systemName: bridge.preferredBridge == entry.name
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(bridge.preferredBridge == entry.name ? 1 : 0.35)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Text(entry.endpoint)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if bridge.discoveredBridges.isEmpty {
                        Text("No Neoy on the LAN. Start one on the desktop (see neox-phone-mcp skill).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Collapsible reference sections, folded by default.
            Section {
                DisclosureGroup("Tools (\(bridge.registeredTools.count))") {
                    ForEach(toolRows, id: \.name) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                            Text(row.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Siri / Shortcuts") {
                    Text("“Hey Siri, create a vlog with Neox”")
                        .font(.subheadline)
                    Text("“Hey Siri, analyze my media with Neox”")
                        .font(.subheadline)
                    Text(AgentHandoff.message(instruction: AgentHandoff.defaultInstruction,
                                              mcpURL: bridge.mcpURL))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private struct ToolRow {
        let name: String
        let summary: String
    }

    /// One-line description per registered tool (UI summary, kept in sync
    /// with the tool definitions).
    private var toolRows: [ToolRow] {
        let descriptions: [String: String] = [
            "media.search": "enumerate library; content filters (has_label/has_text/with_people)",
            "media.export": "stage originals at /files/ (720p/1080p transcode)",
            "media.meta": "EXIF + GPS + vision analysis for one asset",
            "media.thumbnail": "JPEG preview served at /files/",
            "vision.classify": "scene classification",
            "vision.ocr": "text recognition",
            "vision.detect_people": "faces + bodies",
            "vision.similarity": "visually similar assets",
            "vision.index": "batch-analyze library into the persistent index",
            "video.sample_frames": "JPEG frames from a video",
            "video.transcribe": "on-device speech → text",
            "media.clear": "delete staged exports",
            "agent.pilot": "remote UI automation of this app",
            "agent.demo": "spotlight/caption/TTS overlays",
            "agent.handoff": "self-test the phone→bridge handoff path",
        ]
        return bridge.registeredTools.map { ToolRow(name: $0, summary: descriptions[$0] ?? "") }
    }

    private var stateColor: Color {
        switch bridge.state {
        case .running: .green
        case .failed: .red
        default: .orange
        }
    }
}
