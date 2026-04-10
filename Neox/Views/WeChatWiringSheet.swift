import SwiftUI
import WebKitAgent

/// Sheet for wiring a project to a WeChat contact (room or 1:1).
/// Shows contact picker, room member weights, and project type selection.
struct WeChatWiringSheet: View {
    @ObservedObject var weChatService: WeChatService
    let projectId: String
    @Environment(\.dismiss) private var dismiss

    @State private var selectedContact: WeChatContact?
    @State private var memberWeights: [String: Int] = [:]  // memberId → weight
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
                                        .foregroundStyle(isOtherBound ? .tertiary : .secondary)
                                        .frame(width: 28, height: 28)
                                    VStack(alignment: .leading) {
                                        Text(contact.remarkName ?? contact.nickName ?? contact.name)
                                            .foregroundStyle(isOtherBound ? .tertiary : .primary)
                                            .lineLimit(1)
                                        if isOtherBound {
                                            Text("Bound to another project")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
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

                        // Placeholder — room member list would come from WeChatChannel
                        Text("Room members will appear here when connected.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .italic()
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
        } else {
            selectedContact = contact
            if !contact.isRoom {
                memberWeights = [contact.id: 50]
            } else {
                memberWeights = [:]
            }
        }
    }

    private func wire() {
        guard let contact = selectedContact else { return }

        let bound = WeChatContactBindings.BoundContact(
            id: contact.id,
            name: contact.name,
            isRoom: contact.isRoom
        )

        var b = WeChatContactBindings()
        b.contacts = [bound]
        b.routingActive = true
        weChatService.setBindings(b, for: projectId)

        // Save project type to package.json
        saveProjectType(projectType, for: projectId)
    }

    private func unwire() {
        weChatService.setBindings(WeChatContactBindings(), for: projectId)
        selectedContact = nil
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

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? fm.createDirectory(at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: packageURL)
        }
    }
}
