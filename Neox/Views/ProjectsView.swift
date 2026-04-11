import SwiftUI

// MARK: - Project Model

struct ProjectItem: Identifiable, Hashable {
    let id: String       // directory name
    let name: String     // directory name (same as id)
    let displayName: String
    let description: String?
    let repo: String?
    let projectType: String?
    let url: URL

    static func scan(root: URL) -> [ProjectItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { dirURL in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let dirName = dirURL.lastPathComponent
            let jsonURL = dirURL.appendingPathComponent("project.json")

            if let data = try? Data(contentsOf: jsonURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return ProjectItem(
                    id: dirName,
                    name: json["name"] as? String ?? dirName,
                    displayName: json["displayName"] as? String ?? dirName,
                    description: json["description"] as? String,
                    repo: json["repo"] as? String,
                    projectType: json["projectType"] as? String,
                    url: dirURL
                )
            }

            // Directory without project.json — still show it
            let readmeMeta = readFrontMatter(at: dirURL.appendingPathComponent("README.md"))
            return ProjectItem(
                id: dirName,
                name: dirName,
                displayName: readmeMeta["name"] ?? dirName,
                description: readmeMeta["description"],
                repo: nil,
                projectType: nil,
                url: dirURL
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Parse simple YAML front-matter (---\nkey: value\n---) from README.md
    private static func readFrontMatter(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}

// MARK: - Projects View

struct ProjectsView: View {
    let rootURL: URL
    let currentProject: String?
    let onSelect: (ProjectItem?) -> Void
    let onDelete: (ProjectItem) -> Void
    var weChatService: WeChatService?
    var discordService: DiscordService?
    var onSessionReset: ((String) -> Void)?  // projectId → destroy session

    @Environment(\.dismiss) private var dismiss
    @State private var projects: [ProjectItem] = []
    @State private var wiringProject: ProjectItem?
    @State private var discordWiringProject: ProjectItem?

    var body: some View {
        NavigationStack {
            List {
                // "All / No Project" row
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "tray.full")
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        Text("All Messages")
                        Spacer()
                        if currentProject == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .tint(.primary)

                Section(header: Text("Projects (\(projects.count))")) {
                    if projects.isEmpty {
                        Text("No projects yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(projects) { project in
                            let wiredContact = weChatService?.getBindings(for: project.id).contacts.first
                            let discordBinding = discordService?.registeredChannels.first { $0.projectId == project.id }
                            HStack(spacing: 0) {
                                Button {
                                    onSelect(project)
                                    dismiss()
                                } label: {
                                    ProjectRowView(
                                        project: project,
                                        isSelected: currentProject == project.name,
                                        isWired: wiredContact != nil,
                                        wiredContactName: wiredContact?.name,
                                        discordChannelName: discordBinding?.channelName
                                    )
                                }
                                .tint(.primary)

                                // Single channel button — opens the active channel type
                                if wiredContact != nil {
                                    // WeChat is wired — show WeChat button
                                    Button {
                                        wiringProject = project
                                    } label: {
                                        Image(systemName: "bubble.left.and.bubble.right")
                                            .font(.body)
                                            .foregroundStyle(.green)
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("WeChat Settings")
                                } else if discordBinding != nil {
                                    // Discord is wired — show Discord button
                                    Button {
                                        discordWiringProject = project
                                    } label: {
                                        Image(systemName: "number")
                                            .font(.body)
                                            .foregroundStyle(.indigo)
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Discord Channel")
                                } else {
                                    // Nothing wired — direct button for the active channel type
                                    if discordService != nil {
                                        Button {
                                            discordWiringProject = project
                                        } label: {
                                            Image(systemName: "number")
                                                .font(.body)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Wire to Discord")
                                    } else if weChatService != nil {
                                        Button {
                                            wiringProject = project
                                        } label: {
                                            Image(systemName: "bubble.left.and.bubble.right")
                                                .font(.body)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Wire to WeChat")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                projects = ProjectItem.scan(root: rootURL)
            }
            .sheet(item: $wiringProject) { project in
                if let wcs = weChatService {
                    WeChatWiringSheet(
                        weChatService: wcs,
                        projectId: project.id,
                        onSessionReset: { onSessionReset?(project.id) }
                    )
                }
            }
            .sheet(item: $discordWiringProject) { project in
                if let ds = discordService {
                    DiscordWiringSheet(
                        discord: ds,
                        projectId: project.id
                    )
                }
            }
        }
    }
}

// MARK: - Project Row

private struct ProjectRowView: View {
    let project: ProjectItem
    let isSelected: Bool
    var isWired: Bool = false
    var wiredContactName: String? = nil
    var discordChannelName: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.body)
                    .lineLimit(1)
                if let desc = project.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    if let type = project.projectType {
                        Text(type)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.1), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    if isWired, let name = wiredContactName {
                        Label(name, systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.1), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    if let channel = discordChannelName {
                        Label("#\(channel)", systemImage: "number")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.indigo.opacity(0.1), in: Capsule())
                            .foregroundStyle(.indigo)
                    }
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
    }
}
