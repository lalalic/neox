import Foundation

/// Narrow MCP self-test surface for the user-selected Vlog Inbox.
/// These tools intentionally reuse VlogInboxStore/VlogSubmissionWriter so
/// diagnostics exercise the same bookmark and write path as the production UI.
enum VlogDebugTools {
    private static let testPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZgAAAAABJRU5ErkJggg=="
    )!

    static func tools() -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "vlog.inbox.status",
                description: "Inspect the exact Files bookmark used by Create Vlog. Reports whether it exists/resolves, the resolved path/provider clues, iCloud ubiquity, directory entries, and ready manifest-bearing submissions.",
                parameters: MediaTools.schema([:]),
                handler: { _ in
                    await MainActor.run { VlogInboxStore.shared.debugStatusJSON() }
                }
            ),
            ToolDefinition(
                name: "vlog.test.submit",
                description: "Explicitly create one MCP self-test Vlog submission in the configured Vlog Inbox using the production VlogSubmissionWriter and a deterministic valid 1x1 PNG. Use to test iPhone → Files/iCloud → Mac watcher end-to-end.",
                parameters: MediaTools.schema([
                    "submission_id": MediaTools.stringProp("Optional test-prefixed id. Default is mcp-test-<UTC timestamp>. Must start with mcp-test-."),
                    "instruction": MediaTools.stringProp("Optional test instruction. Defaults to a clearly marked MCP self-test instruction."),
                ]),
                handler: { args in
                    let requestedID = MediaTools.str(args, "submission_id")
                    let instruction = MediaTools.str(args, "instruction")
                    return await MainActor.run {
                        VlogInboxStore.shared.createMCPTestSubmission(
                            requestedID: requestedID,
                            instruction: instruction,
                            testPNG: testPNG
                        )
                    }
                }
            ),
        ]
    }
}

extension VlogInboxStore {
    func debugStatusJSON() -> String {
        let bookmarkExists = UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
        guard bookmarkExists else {
            return MediaTools.jsonString([
                "bookmark_exists": false,
                "configured_folder_name": folderName ?? NSNull(),
                "resolved": false,
                "error": "Choose your iCloud Drive Vlog Inbox first.",
            ])
        }

        do {
            let folder = try resolvedFolder()
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let snapshot = try VlogInboxInspector.inspect(folderURL: folder)
            return MediaTools.jsonString([
                "bookmark_exists": true,
                "resolved": true,
                "security_scope_accessed": accessed,
                "folder_name": snapshot.folderName,
                "path": snapshot.path,
                "url": folder.absoluteString,
                "exists": snapshot.exists,
                "is_directory": snapshot.isDirectory,
                "is_ubiquitous": snapshot.isUbiquitous,
                "entries": snapshot.entries,
                "ready_submissions": snapshot.readySubmissions,
            ])
        } catch {
            return MediaTools.jsonString([
                "bookmark_exists": true,
                "resolved": false,
                "configured_folder_name": folderName ?? NSNull(),
                "error": error.localizedDescription,
            ])
        }
    }

    func createMCPTestSubmission(requestedID: String?, instruction: String?, testPNG: Data) -> String {
        let id: String
        if let requestedID, !requestedID.isEmpty {
            guard requestedID.hasPrefix("mcp-test-") else {
                return "Error: submission_id must start with mcp-test-"
            }
            id = requestedID
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            id = "mcp-test-\(formatter.string(from: Date()))"
        }

        do {
            let folder = try resolvedFolder()
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let message = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = try VlogSubmissionWriter.write(
                inboxURL: folder,
                submissionID: id,
                instruction: (message?.isEmpty == false) ? message : "[MCP SELF-TEST] Verify Neox Vlog Inbox sync and watcher ingestion. Do not publish.",
                payloads: [VlogSubmissionPayload(filename: "001.png", data: testPNG)]
            )
            return MediaTools.jsonString([
                "ok": true,
                "submission_id": id,
                "submission_path": url.path,
                "manifest_path": url.appendingPathComponent("manifest.json").path,
                "media_path": url.appendingPathComponent("media/001.png").path,
                "security_scope_accessed": accessed,
            ])
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
