import Foundation
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// The current Gateway accepts text only. Import readable text explicitly,
/// instead of pretending that photo/file bytes are sent as attachments.
enum ChatComposerImport {
    enum ImportError: Error {
        case unsupportedFile
        case fileTooLarge
        case unreadable
    }

    static func textFromFile(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 3_000_000 else { throw ImportError.fileTooLarge }

        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw ImportError.unreadable }
            return (0..<min(document.pageCount, 20))
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard type?.conforms(to: .text) == true || type == .json ||
              ["txt", "md", "json", "csv", "log"].contains(url.pathExtension.lowercased())
        else { throw ImportError.unsupportedFile }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .utf16) else {
            throw ImportError.unreadable
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func textFromPhoto(_ item: PhotosPickerItem) async throws -> String {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ImportError.unreadable
        }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(data: data).perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    static func append(_ extracted: String, to draft: String, source: String) -> String {
        let value = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, draft.count < 2000 else { return draft }
        let prefix = draft.isEmpty ? "" : "\n\n"
        let label = "[\(source)]\n"
        return draft + String((prefix + label + value).prefix(2000 - draft.count))
    }
}
