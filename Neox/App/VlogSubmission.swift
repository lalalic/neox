import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct VlogSubmissionMedia: Codable, Equatable {
    let path: String
}

struct VlogSubmissionManifest: Codable, Equatable {
    let schema_version: Int
    let submission_id: String
    let instruction: String?
    let media: [VlogSubmissionMedia]
}

struct VlogSubmissionPayload {
    let filename: String
    let data: Data
}

enum VlogSubmissionWriter {
    static func write(
        inboxURL: URL,
        submissionID: String,
        instruction: String?,
        payloads: [VlogSubmissionPayload]
    ) throws -> URL {
        guard !payloads.isEmpty else {
            throw NSError(domain: "Neox.Vlog", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Select at least one photo or video."])
        }
        guard submissionID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "Neox.Vlog", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid submission id."])
        }

        let fm = FileManager.default
        let submissionURL = inboxURL.appendingPathComponent(submissionID, isDirectory: true)
        let mediaURL = submissionURL.appendingPathComponent("media", isDirectory: true)
        guard !fm.fileExists(atPath: submissionURL.path) else {
            throw NSError(domain: "Neox.Vlog", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Submission already exists."])
        }

        do {
            try fm.createDirectory(at: mediaURL, withIntermediateDirectories: true)
            var manifestMedia: [VlogSubmissionMedia] = []
            for payload in payloads {
                guard payload.filename == URL(fileURLWithPath: payload.filename).lastPathComponent,
                      !payload.filename.isEmpty else {
                    throw NSError(domain: "Neox.Vlog", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Unsafe media filename."])
                }
                let relative = "media/\(payload.filename)"
                try payload.data.write(to: mediaURL.appendingPathComponent(payload.filename), options: .atomic)
                manifestMedia.append(VlogSubmissionMedia(path: relative))
            }

            let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
            let manifest = VlogSubmissionManifest(
                schema_version: 1,
                submission_id: submissionID,
                instruction: (trimmed?.isEmpty == false) ? trimmed : nil,
                media: manifestMedia
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(manifest)

            // The final-ready signal: this is deliberately the last write.
            try data.write(to: submissionURL.appendingPathComponent("manifest.json"), options: .atomic)
            return submissionURL
        } catch {
            try? fm.removeItem(at: submissionURL)
            throw error
        }
    }
}

@MainActor
final class VlogInboxStore: ObservableObject {
    static let shared = VlogInboxStore()

    @Published private(set) var folderName: String?
    @Published private(set) var status: String?

    private let bookmarkKey = "vlogInboxBookmark"

    private init() {
        folderName = (try? resolvedFolder())?.lastPathComponent
    }

    func configure(folderURL: URL) throws {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        let bookmark = try folderURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        folderName = folderURL.lastPathComponent
        status = "Vlog Inbox configured."
    }

    func submit(items: [PhotosPickerItem], instruction: String) async throws -> String {
        let folder = try resolvedFolder()
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }

        var payloads: [VlogSubmissionPayload] = []
        for (index, item) in items.enumerated() {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw NSError(domain: "Neox.Vlog", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Could not load selected media."])
            }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "bin"
            payloads.append(VlogSubmissionPayload(
                filename: String(format: "%03d.%@", index + 1, ext),
                data: data
            ))
        }

        let id = UUID().uuidString.lowercased()
        let url = try VlogSubmissionWriter.write(
            inboxURL: folder,
            submissionID: id,
            instruction: instruction,
            payloads: payloads
        )
        status = "Submitted \(items.count) item(s): \(id)"
        return url.lastPathComponent
    }

    private func resolvedFolder() throws -> URL {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw NSError(domain: "Neox.Vlog", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Choose your iCloud Drive Vlog Inbox first."])
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            let refreshed = try url.bookmarkData(options: .minimalBookmark,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
        }
        return url
    }
}

struct VlogSubmissionView: View {
    @ObservedObject private var store = VlogInboxStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PhotosPickerItem] = []
    @State private var instruction = ""
    @State private var showingFolderPicker = false
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud Inbox") {
                    Text(store.folderName ?? "Not configured")
                        .foregroundStyle(store.folderName == nil ? .secondary : .primary)
                    Button("Choose Vlog Inbox") { showingFolderPicker = true }
                }

                Section("Media") {
                    PhotosPicker(
                        selection: $items,
                        maxSelectionCount: 20,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label(items.isEmpty ? "Select Photos & Videos" : "\(items.count) selected",
                              systemImage: "photo.stack")
                    }
                }

                Section("Instruction") {
                    TextField("Optional vlog instruction", text: $instruction, axis: .vertical)
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                } else if let status = store.status {
                    Section {
                        Text(status).foregroundStyle(.secondary)
                    }
                }

                Button {
                    isSubmitting = true
                    errorText = nil
                    Task {
                        do {
                            _ = try await store.submit(items: items, instruction: instruction)
                            items = []
                            instruction = ""
                        } catch {
                            errorText = error.localizedDescription
                        }
                        isSubmitting = false
                    }
                } label: {
                    HStack {
                        if isSubmitting { ProgressView() }
                        Text("Create Vlog Submission")
                    }
                }
                .disabled(isSubmitting || items.isEmpty || store.folderName == nil)
            }
            .navigationTitle("Create Vlog")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let folder = try result.get().first else { return }
                    try store.configure(folderURL: folder)
                    errorText = nil
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
