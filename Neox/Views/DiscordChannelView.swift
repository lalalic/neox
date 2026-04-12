import SwiftUI

/// Settings section for Discord connection status (global settings).
/// Shows connection toggle, server ID, invite link, and bound channel count.
struct DiscordChannelView: View {
    @ObservedObject var discord: DiscordService
    @EnvironmentObject var coordinator: AgentCoordinator

    private let botClientId = "1489316184578068755"

    private var inviteURL: URL {
        URL(string: "https://discord.com/oauth2/authorize?client_id=\(botClientId)&permissions=3072&scope=bot")!
    }

    var body: some View {
        Section {
            Toggle("Enable Discord", isOn: Binding(
                get: { coordinator.channelType == "discord" },
                set: { newValue in
                    if newValue {
                        coordinator.channelType = "discord"
                    } else {
                        coordinator.channelType = ""
                    }
                }
            ))

            // Connection status (read-only — shares main relay WS)
            HStack {
                Text("Status")
                Spacer()
                if discord.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("Disconnected", systemImage: "circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            TextField("Server ID", text: $discord.guildId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.numberPad)

            // Invite bot button
            Button {
                UIApplication.shared.open(inviteURL)
            } label: {
                Label("Invite Bot to Server", systemImage: "link.badge.plus")
            }
        }
    }
}

// MARK: - Discord Wiring Sheet (per-project)

/// Sheet for wiring a project to a Discord channel.
/// Fetches channels from the configured server and shows a picker.
struct DiscordWiringSheet: View {
    @ObservedObject var discord: DiscordService
    let projectId: String
    @Environment(\.dismiss) private var dismiss

    @State private var channels: [DiscordService.ChannelInfo] = []
    @State private var isLoading = true
    @State private var selectedChannel: DiscordService.ChannelInfo?
    @State private var isSaving = false
    @State private var errorText: String?

    /// Current binding for this project (if any).
    private var currentBinding: DiscordService.ChannelBinding? {
        discord.registeredChannels.first { $0.projectId == projectId }
    }

    var body: some View {
        NavigationStack {
            List {
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
                    }
                } else if discord.guildId.isEmpty {
                    Section {
                        Text("Set a Server ID in Discord settings first.")
                            .foregroundStyle(.secondary)
                    }
                } else if isLoading {
                    Section("Select Channel") {
                        ProgressView("Loading channels…")
                    }
                } else if channels.isEmpty {
                    Section("Select Channel") {
                        Text("No text channels found")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Select Channel") {
                        ForEach(channels) { channel in
                            let isCurrent = currentBinding?.channelId == channel.channelId
                            let isBoundToOther = !isCurrent && discord.registeredChannels.contains { $0.channelId == channel.channelId }
                            Button {
                                if selectedChannel?.channelId == channel.channelId {
                                    selectedChannel = nil
                                } else {
                                    selectedChannel = channel
                                }
                            } label: {
                                HStack {
                                    Text("#\(channel.channelName)")
                                    Spacer()
                                    if isCurrent {
                                        Text("current")
                                            .font(.caption)
                                            .foregroundStyle(.indigo)
                                    } else if isBoundToOther {
                                        Text("other project")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if selectedChannel?.channelId == channel.channelId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .disabled(isCurrent || isBoundToOther)
                        }
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
                    .disabled(selectedChannel == nil || isSaving)
                    .bold()
                }
            }
            .task {
                if discord.isConnected && !discord.guildId.isEmpty {
                    await loadChannels()
                }
            }
        }
    }

    private func loadChannels() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let guilds = try await discord.fetchGuilds()
            // Flatten to text channels only
            channels = guilds.flatMap { $0.channels }.filter { $0.type == 0 }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func wireChannel() async {
        guard let channel = selectedChannel else { return }
        isSaving = true
        defer { isSaving = false }

        // Remove existing binding for this project first
        if let existing = currentBinding {
            try? await discord.unregisterChannel(channelId: existing.channelId)
        }

        do {
            _ = try await discord.registerChannel(channelId: channel.channelId, projectId: projectId)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
