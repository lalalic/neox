import Photos
import SwiftUI

/// Status screen — the only human-facing surface. Shows where to connect,
/// what the server is doing, and grants Photos permission once.
struct StatusView: View {
    @EnvironmentObject private var bridge: ServerController
    // Reference sections start collapsed; tap a header to expand.
    @State private var neoyExpanded = false
    @State private var siriExpanded = false

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

            if let transaction = bridge.transaction {
                PhoneTransactionBanner(snapshot: transaction)
                    .task(id: transaction.id) {
                        while !Task.isCancelled {
                            if bridge.transaction?.state != .active {
                                break
                            }

                            bridge.refreshTransaction()

                            do {
                                try await Task.sleep(for: .seconds(1))
                            } catch {
                                return
                            }
                        }

                        guard !Task.isCancelled, bridge.transaction != nil else { return }

                        do {
                            try await Task.sleep(for: .seconds(60))
                        } catch {
                            return
                        }

                        bridge.dismissReleasedTransaction()
                    }
            }

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
        // No .onAppear ensureRunning() here — NeoxApp's scenePhase(.active)
        // handler already restarts on every foreground. Keeping both would
        // restart twice at launch and log two 'listening' lines.
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
                DisclosureGroup("Neoy (\(bridge.discoveredBridges.count))", isExpanded: $neoyExpanded) {
                    ForEach(bridge.discoveredBridges) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: bridge.preferredBridge == entry.name
                                ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Color.accentColor)
                                .opacity(bridge.preferredBridge == entry.name ? 1 : 0.35)
                            // Single line: name (semibold) + smaller address,
                            // never wraps — scale/truncate together instead.
                            (Text(entry.displayName)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                             + Text("  " + entry.endpointText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // Select button kept OUTSIDE the row-tap target:
                            // a full-row Button inside DisclosureGroup content
                            // swallows taps, breaking fold/unfold.
                            Button {
                                bridge.preferredBridge = entry.name
                            } label: {
                                Image(systemName: "hand.tap")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(.borderless)
                        }
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

            // Supported App Intents — what Siri/Shortcuts can run, with the
            // phrase for each. Free-form instruction text is edited in the
            // Shortcuts app (App Intents allows no free-form placeholders).
            Section {
                DisclosureGroup("Siri / Shortcuts", isExpanded: $siriExpanded) {
                    ForEach(intentRows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.intent)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                            ForEach(row.phrases, id: \.self) { phrase in
                                Text("“Hey Siri, \(phrase)”")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private struct ToolRow {
        let name: String
        let summary: String
    }

    /// One row per supported App Intent: name + its Siri phrases (mirrors
    /// NeoxShortcuts.appShortcuts — keep in sync).
    private struct IntentRow: Identifiable {
        let id: String
        let intent: String
        let phrases: [String]
    }

    private var intentRows: [IntentRow] {
        [
            IntentRow(id: "run-agent", intent: "Run Agent Task", phrases: [
                "create a vlog with Neox",
                "make a vlog with Neox",
                "run my agent with Neox",
            ]),
            IntentRow(id: "analyze-media", intent: "Analyze Media", phrases: [
                "analyze my media with Neox",
                "index my photos with Neox",
            ]),
        ]
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

private struct PhoneTransactionBanner: View {
    let snapshot: PhoneTransactionSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isActive = snapshot.state == .active
            let now = context.date

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    isActive ? "NeoX phone work active" : terminalTitle,
                    systemImage: isActive ? "iphone.radiowaves.left.and.right" : terminalIcon
                )
                .font(.headline)

                Text(
                    isActive
                        ? "Keep NeoX in the foreground while phone work is active."
                        : terminalMessage
                )
                .font(.subheadline.weight(.semibold))

                Text(snapshot.label)
                    .font(.subheadline)
                    .lineLimit(1)

                if let reason = snapshot.reason {
                    Text(reason)
                        .font(.caption)
                        .lineLimit(2)
                }

                if isActive {
                    Text("Elapsed \(format(now.timeIntervalSince(snapshot.startedAt))) · time left \(format(max(0, snapshot.expiresAt.timeIntervalSince(now))))")
                        .font(.caption.monospacedDigit())
                } else if let endedAt = snapshot.endedAt {
                    Text("Released at \(endedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .foregroundStyle(.black)
            .background(isActive ? .orange : terminalColor)
        }
    }

    private var terminalTitle: String {
        switch snapshot.state {
        case .completed: "Phone work complete"
        case .failed: "Phone work failed"
        case .cancelled: "Phone work cancelled"
        case .timeout: "Phone work timed out"
        case .active: "NeoX phone work active"
        }
    }

    private var terminalIcon: String {
        switch snapshot.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "minus.circle.fill"
        case .timeout: "clock.badge.exclamationmark"
        case .active: "iphone.radiowaves.left.and.right"
        }
    }

    private var terminalMessage: String {
        switch snapshot.state {
        case .completed:
            "NeoX is released. You can use your phone normally; desktop processing may continue."
        case .failed:
            "NeoX is released after phone work failed. You can use your phone normally; desktop processing status is unchanged."
        case .cancelled:
            "NeoX is released after phone work was cancelled. You can use your phone normally; desktop processing status is unchanged."
        case .timeout:
            "NeoX is released after phone work timed out. You can use your phone normally; desktop processing status is unchanged."
        case .active:
            "Keep NeoX in the foreground while phone work is active."
        }
    }

    private var terminalColor: Color {
        switch snapshot.state {
        case .completed: .green
        case .failed: .red
        case .timeout: .orange
        case .cancelled: .gray
        case .active: .orange
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        Duration.seconds(Int(interval.rounded())).formatted(.time(pattern: .minuteSecond))
    }
}
