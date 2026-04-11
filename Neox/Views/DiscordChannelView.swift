import SwiftUI

/// Settings section for Discord channel management.
/// Shows connection status, registered channel bindings, and allows adding/removing channels.
struct DiscordChannelView: View {
    @ObservedObject var discord: DiscordService

    @State private var guilds: [DiscordService.GuildInfo] = []
    @State private var showAddSheet = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Discord") {
            // Connection toggle
            Toggle("Connected", isOn: Binding(
                get: { discord.isConnected },
                set: { newValue in
                    Task {
                        if newValue { await discord.connect() }
                        else { discord.disconnect() }
                    }
                }
            ))

            // Registered channels
            if !discord.registeredChannels.isEmpty {
                ForEach(discord.registeredChannels) { binding in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(binding.channelName ?? binding.channelId)")
                                .font(.body)
                            Text(binding.projectId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let guild = binding.guildName {
                            Text(guild)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                try? await discord.unregisterChannel(channelId: binding.channelId)
                            }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }

            // Add channel button
            if discord.isConnected {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Channel", systemImage: "plus.circle")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddDiscordChannelSheet(discord: discord, guilds: $guilds, isLoading: $isLoading)
                .task {
                    await loadGuilds()
                }
        }
    }

    private func loadGuilds() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guilds = try await discord.fetchGuilds()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Add Channel Sheet

private struct AddDiscordChannelSheet: View {
    @ObservedObject var discord: DiscordService
    @Binding var guilds: [DiscordService.GuildInfo]
    @Binding var isLoading: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var selectedChannel: DiscordService.ChannelInfo?
    @State private var selectedGuild: DiscordService.GuildInfo?
    @State private var projectId = ""
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView("Loading channels...")
                } else if guilds.isEmpty {
                    Text("No guilds available")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(guilds) { guild in
                        Section(guild.guildName) {
                            let textChannels = guild.channels.filter { $0.type == 0 }
                            ForEach(textChannels) { channel in
                                let alreadyBound = discord.registeredChannels.contains { $0.channelId == channel.channelId }
                                Button {
                                    selectedChannel = channel
                                    selectedGuild = guild
                                } label: {
                                    HStack {
                                        Text("#\(channel.channelName)")
                                        Spacer()
                                        if alreadyBound {
                                            Text("bound")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else if selectedChannel?.channelId == channel.channelId {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                                .disabled(alreadyBound)
                            }
                        }
                    }
                }

                if selectedChannel != nil {
                    Section("Project") {
                        TextField("Project ID (e.g. my-project)", text: $projectId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
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
            .navigationTitle("Add Discord Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await addChannel() }
                    }
                    .disabled(selectedChannel == nil || projectId.isEmpty || isSaving)
                }
            }
        }
    }

    private func addChannel() async {
        guard let channel = selectedChannel else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await discord.registerChannel(channelId: channel.channelId, projectId: projectId)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
