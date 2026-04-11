import SwiftUI

/// Settings section for Discord connection status (global settings).
/// Shows connection toggle and registered channel count.
struct DiscordChannelView: View {
    @ObservedObject var discord: DiscordService
    @EnvironmentObject var coordinator: AgentCoordinator

    var body: some View {
        Section("Discord") {
            // Connection toggle
            Toggle("Connected", isOn: Binding(
                get: { discord.isConnected },
                set: { newValue in
                    Task {
                        if newValue {
                            // Always use local relay for Discord (bot runs locally)
                            let parsed = coordinator.parseLocalRelayURL()
                            discord.updateRelay(host: parsed.host, port: parsed.port)
                            await discord.connect()
                        } else {
                            discord.disconnect()
                        }
                    }
                }
            ))

            if !discord.registeredChannels.isEmpty {
                HStack {
                    Text("Channels")
                    Spacer()
                    Text("\(discord.registeredChannels.count) bound")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Discord Wiring Sheet (per-project)

/// Sheet for wiring a project to a Discord channel.
/// User enters server ID and channel ID manually (from Discord Developer Mode).
struct DiscordWiringSheet: View {
    @ObservedObject var discord: DiscordService
    let projectId: String
    @Environment(\.dismiss) private var dismiss

    @State private var serverId = ""
    @State private var channelId = ""
    @State private var isSaving = false
    @State private var errorText: String?

    /// Current binding for this project (if any).
    private var currentBinding: DiscordService.ChannelBinding? {
        discord.registeredChannels.first { $0.projectId == projectId }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Current binding info
                if let binding = currentBinding {
                    Section("Current Channel") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("#\(binding.channelName ?? binding.channelId)")
                                    .font(.body)
                                if let guild = binding.guildName {
                                    Text(guild)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    try? await discord.unregisterChannel(channelId: binding.channelId)
                                }
                            } label: {
                                Text("Remove")
                                    .font(.caption)
                            }
                        }
                    }
                }

                if !discord.isConnected {
                    Section {
                        Label("Discord is not connected", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                        Text("Enable Discord in Settings first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Channel") {
                        TextField("Server ID", text: $serverId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numberPad)
                        TextField("Channel ID", text: $channelId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numberPad)
                    }

                    Section {
                        Text("In Discord, enable Developer Mode (Settings → Advanced), then right-click a server or channel → Copy ID.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Discord Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Wire") {
                        Task { await wireChannel() }
                    }
                    .disabled(channelId.isEmpty || isSaving || !discord.isConnected)
                    .bold()
                }
            }
            .onAppear {
                // Pre-fill from existing binding
                if let binding = currentBinding {
                    channelId = binding.channelId
                }
            }
        }
    }

    private func wireChannel() async {
        let cid = channelId.trimmingCharacters(in: .whitespaces)
        guard !cid.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        // Remove existing binding for this project first
        if let existing = currentBinding {
            try? await discord.unregisterChannel(channelId: existing.channelId)
        }

        do {
            _ = try await discord.registerChannel(channelId: cid, projectId: projectId)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
