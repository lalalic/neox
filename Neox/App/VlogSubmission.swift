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
    static let ubiquityContainerIdentifier = "iCloud.com.neox.app"
    static let inboxRelativePath = "Documents/Vlog Inbox"


    private init() {}

    func submit(items: [PhotosPickerItem], instruction: String) async throws -> String {
        let folder = try resolvedFolder()
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
        return url.lastPathComponent
    }

    func resolvedFolder() throws -> URL {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: Self.ubiquityContainerIdentifier
        ) else {
            throw NSError(domain: "Neox.Vlog", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Neox iCloud Drive is unavailable. Sign in to iCloud Drive and try again."])
        }
        let folder = container.appendingPathComponent(Self.inboxRelativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}


struct VlogInboxSnapshot: Equatable {
    let path: String
    let folderName: String
    let exists: Bool
    let isDirectory: Bool
    let isUbiquitous: Bool
    let entries: [String]
    let readySubmissions: [String]
}

enum VlogInboxInspector {
    static func inspect(folderURL: URL) throws -> VlogInboxSnapshot {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: folderURL.path, isDirectory: &isDirectory)
        let entries = exists && isDirectory.boolValue
            ? try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            : []
        let names = entries.map(\.lastPathComponent).sorted()
        let ready = entries.filter { entry in
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &directory), directory.boolValue else { return false }
            return fm.fileExists(atPath: entry.appendingPathComponent("manifest.json").path)
        }.map(\.lastPathComponent).sorted()
        return VlogInboxSnapshot(
            path: folderURL.path,
            folderName: folderURL.lastPathComponent,
            exists: exists,
            isDirectory: isDirectory.boolValue,
            isUbiquitous: fm.isUbiquitousItem(at: folderURL),
            entries: names,
            readySubmissions: ready
        )
    }
}

struct VlogSubmissionView: View {
    private let store = VlogInboxStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PhotosPickerItem] = []
    @State private var instruction = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
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
                    Text(errorText).foregroundStyle(.red)
                }

                Button {
                    isSubmitting = true
                    errorText = nil
                    Task {
                        do {
                            _ = try await store.submit(items: items, instruction: instruction)
                            items = []
                            instruction = ""
                            dismiss()
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
                .disabled(isSubmitting || items.isEmpty)
            }
            .navigationTitle("Create Vlog")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
