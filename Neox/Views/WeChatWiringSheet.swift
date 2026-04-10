import SwiftUI
import WebKitAgent

/// Sheet for wiring a project to a WeChat contact (room or 1:1).
/// Shows contact picker, room member weights, and project type selection.
struct WeChatWiringSheet: View {
    @ObservedObject var weChatService: WeChatService
    let projectId: String
    var onSessionReset: (() -> Void)?  // Called when wire/unwire so coordinator can destroy stale session
    @Environment(\.dismiss) private var dismiss

    @State private var selectedContact: WeChatContact?
    @State private var memberWeights: [String: Int] = [:]  // memberId → weight
    @State private var roomMembers: [WeChatRoomMember] = []
    @State private var loadingMembers = false
    @State private var searchText = ""
    @State private var projectType: String = "project-assistant"

    private var bindings: WeChatContactBindings {
        weChatService.getBindings(for: projectId)
    }

    /// Contacts already bound to other projects (disabled in picker).
    private var otherBoundIDs: Set<String> {
        var ids = Set<String>()
        for (pid, b) in weChatService.projectBindings where pid != projectId {
            for c in b.contacts {
                ids.insert(c.id)
            }
        }
        return ids
    }

    /// Currently wired contact for this project (if any).
    private var currentWired: WeChatContactBindings.BoundContact? {
        bindings.contacts.first
    }

    private var filteredContacts: [WeChatContact] {
        let all = weChatService.contacts
        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(query) ||
            ($0.remarkName?.lowercased().contains(query) ?? false) ||
            ($0.nickName?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Current wiring status
                if let current = currentWired {
                    Section("Currently Wired") {
                        HStack {
                            Image(systemName: current.isRoom ? "person.3.fill" : "person.circle.fill")
                                .foregroundStyle(.green)
                            Text(current.name)
                            Spacer()
                            Button("Unwire") {
                                unwire()
                            }
                            .foregroundStyle(.red)
                            .font(.caption)
                        }
                    }
                }

                // Project type picker
                Section("Project Type") {
                    Picker("Type", selection: $projectType) {
                        Text("Project Assistant").tag("project-assistant")
                        Text("WeChat Assistant").tag("wechat-assistant")
                    }
                    .pickerStyle(.segmented)

                    if projectType == "project-assistant" {
                        Text("Agent responds with 🤖 prefix. Acts as project helper.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Agent replies as you (no prefix). Seamless auto-reply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Contact picker
                if weChatService.contacts.isEmpty {
                    Section("Select Contact") {
                        if weChatService.isOnline {
                            ProgressView("Loading contacts…")
                        } else {
                            Label("WeChat is offline", systemImage: "wifi.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("Select Contact") {
                        ForEach(filteredContacts) { contact in
                            let isOtherBound = otherBoundIDs.contains(contact.id)
                            let isSelected = selectedContact?.id == contact.id

                            Button {
                                guard !isOtherBound else { return }
                                selectContact(contact)
                            } label: {
                                HStack {
                                    Image(systemName: contact.isRoom ? "person.3.fill" : "person.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(isOtherBound ? .gray.opacity(0.3) : .secondary)
                                        .frame(width: 28, height: 28)
                                    VStack(alignment: .leading) {
                                        Text(contact.remarkName ?? contact.nickName ?? contact.name)
                                            .foregroundStyle(isOtherBound ? .gray.opacity(0.3) : .primary)
                                            .lineLimit(1)
                                        if isOtherBound {
                                            Text("Bound to another project")
                                                .font(.caption2)
                                                .foregroundStyle(.gray.opacity(0.3))
                                        }
                                    }
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .disabled(isOtherBound)
                        }
                    }
                }

                // Room member weights (shown when room is selected)
                if let contact = selectedContact, contact.isRoom {
                    Section("Member Weights") {
                        Text("Assign decision weight to each member. Higher weight = more authority.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if loadingMembers {
                            ProgressView("Loading members…")
                        } else if roomMembers.isEmpty {
                            Text("No members loaded. WeChat may be offline.")
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .italic()
                        } else {
                            ForEach(roomMembers) { member in
                                MemberWeightRow(
                                    name: member.name,
                                    weight: Binding(
                                        get: { memberWeights[member.userName, default: 50] },
                                        set: { memberWeights[member.userName] = $0 }
                                    )
                                )
                            }
                        }
                    }
                }

                // 1:1 info (shown when person is selected)
                if let contact = selectedContact, !contact.isRoom {
                    Section("1:1 Settings") {
                        HStack {
                            Text("Weight")
                            Spacer()
                            Text("50 (default)")
                                .foregroundStyle(.secondary)
                        }
                        Text("In 1:1 mode, the other person has weight 50. You keep final say from Neox (weight 100).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search contacts")
            .navigationTitle("Wire to WeChat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Wire") {
                        wire()
                        dismiss()
                    }
                    .disabled(selectedContact == nil)
                    .bold()
                }
            }
        }
    }

    // MARK: - Actions

    private func selectContact(_ contact: WeChatContact) {
        if selectedContact?.id == contact.id {
            selectedContact = nil
            memberWeights = [:]
            roomMembers = []
        } else {
            selectedContact = contact
            if !contact.isRoom {
                memberWeights = [contact.id: 50]
                roomMembers = []
            } else {
                memberWeights = [:]
                loadRoomMembers(roomId: contact.userName)
            }
        }
    }

    private func loadRoomMembers(roomId: String) {
        loadingMembers = true
        Task {
            let members = await weChatService.getRoomMembers(roomId: roomId)
            roomMembers = members
            // Default all members to weight 50
            for member in members {
                if memberWeights[member.userName] == nil {
                    memberWeights[member.userName] = 50
                }
            }
            loadingMembers = false
        }
    }

    private func wire() {
        guard let contact = selectedContact else { return }

        var members: [String: WeChatMember]?
        if contact.isRoom, !roomMembers.isEmpty {
            var dict: [String: WeChatMember] = [:]
            for member in roomMembers {
                let weight = memberWeights[member.userName] ?? 50
                dict[member.userName] = WeChatMember(name: member.name, weight: weight)
            }
            members = dict
        }

        let bound = WeChatContactBindings.BoundContact(
            id: contact.id,
            name: contact.name,
            isRoom: contact.isRoom,
            weight: contact.isRoom ? nil : 50,
            autoReply: projectType == "wechat-assistant" ? true : nil,
            members: members
        )

        var b = WeChatContactBindings()
        b.contacts = [bound]
        b.routingActive = true
        weChatService.setBindings(b, for: projectId)

        // Save project type to package.json
        saveProjectType(projectType, for: projectId)

        // Generate default context.md for wechat-assistant projects
        if projectType == "wechat-assistant" {
            ensureContextMd(for: projectId)
        }

        // Destroy stale session so it's recreated with correct type
        onSessionReset?()
    }

    private func unwire() {
        weChatService.setBindings(WeChatContactBindings(), for: projectId)
        selectedContact = nil
        roomMembers = []
        memberWeights = [:]
        onSessionReset?()
    }

    private func saveProjectType(_ type: String, for projectId: String) {
        let fm = FileManager.default
        let workspaceURL = weChatService.workspaceURL
        let packageURL = workspaceURL
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("package.json")

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: packageURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["projectType"] = type
        json["name"] = projectId

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? fm.createDirectory(at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: packageURL)
        }
    }

    private func ensureContextMd(for projectId: String) {
        let fm = FileManager.default
        let workspaceURL = weChatService.workspaceURL
        let contextURL = workspaceURL
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("context.md")

        // Don't overwrite existing context.md
        guard !fm.fileExists(atPath: contextURL.path) else { return }

        // Copy from template if available
        let templateURL = workspaceURL
            .appendingPathComponent(".templates/projects/wechat-assistant/context.md")
        if fm.fileExists(atPath: templateURL.path),
           let template = try? String(contentsOf: templateURL, encoding: .utf8) {
            try? template.write(to: contextURL, atomically: true, encoding: .utf8)
        } else {
            // Inline fallback
            let fallback = """
            # WeChat Assistant

            ## My Persona
            Brief professional tone. Keep replies concise and friendly.

            ## Behavior Rules
            - Routine questions → auto-reply
            - Match the language the sender uses
            - Keep replies under 3 sentences unless asked for more

            ### Guardrails
            - Never schedule meetings or make commitments on my behalf
            - Escalate anything involving money, legal matters, or contracts
            - If unsure about intent, ask me first
            - Don't share internal/private details

            ## Contacts

            ### Default
            For anyone not listed below: polite, brief, escalate if unsure.
            """
            try? fallback.write(to: contextURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Member Weight Row

private struct MemberWeightRow: View {
    let name: String
    @Binding var weight: Int

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(name)
                    .lineLimit(1)
                Spacer()
                Text("\(weight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { Double(weight) },
                set: { weight = Int($0) }
            ), in: 0...100, step: 10)
            .tint(weight == 0 ? .gray : weight >= 80 ? .green : .blue)
        }
        .padding(.vertical, 2)
    }
}
