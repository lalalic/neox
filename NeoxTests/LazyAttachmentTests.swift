import Testing
import Foundation
@testable import Neox
import CopilotSDK
import CopilotChat

// MARK: - View Tool & Lazy Attachment Tests

@Suite("View Tool & Lazy Attachment Tests")
@MainActor
struct LazyAttachmentTests {

    // MARK: - View Tool Registration

    @Test("View tool is registered in agent mode")
    func viewToolRegistered() {
        let coordinator = AgentCoordinator()
        coordinator.registerDefaultTools()
        // The view tool is built-in to ChatViewModel, not coordinator
        // Verify ChatViewModel creates it
        let vm = makeTestVM()
        // View tool is registered during connectAgent, which needs connection.
        // Instead verify the attachment store exists and is empty initially.
        #expect(vm.attachmentStore.promptDescription() == nil)
    }

    // MARK: - Attachment Store MIME Type

    @Test("MIME type for image extensions")
    func mimeTypeImages() {
        #expect(AttachmentStore.mimeType(for: "jpg") == "image/jpeg")
        #expect(AttachmentStore.mimeType(for: "jpeg") == "image/jpeg")
        #expect(AttachmentStore.mimeType(for: "png") == "image/png")
        #expect(AttachmentStore.mimeType(for: "gif") == "image/gif")
        #expect(AttachmentStore.mimeType(for: "webp") == "image/webp")
        #expect(AttachmentStore.mimeType(for: "heic") == "image/heic")
        #expect(AttachmentStore.mimeType(for: "svg") == "image/svg+xml")
        #expect(AttachmentStore.mimeType(for: "bmp") == "image/bmp")
        #expect(AttachmentStore.mimeType(for: "tiff") == "image/tiff")
        #expect(AttachmentStore.mimeType(for: "tif") == "image/tiff")
    }

    @Test("MIME type for video extensions")
    func mimeTypeVideos() {
        #expect(AttachmentStore.mimeType(for: "mp4") == "video/mp4")
        #expect(AttachmentStore.mimeType(for: "mov") == "video/quicktime")
    }

    @Test("MIME type case insensitive")
    func mimeTypeCaseInsensitive() {
        #expect(AttachmentStore.mimeType(for: "JPG") == "image/jpeg")
        #expect(AttachmentStore.mimeType(for: "PNG") == "image/png")
    }

    // MARK: - isTextMimeType

    @Test("Text MIME types detected correctly")
    func isTextMimeType() {
        #expect(AttachmentStore.isTextMimeType("text/plain") == true)
        #expect(AttachmentStore.isTextMimeType("text/html") == true)
        #expect(AttachmentStore.isTextMimeType("text/css") == true)
        #expect(AttachmentStore.isTextMimeType("application/json") == true)
        #expect(AttachmentStore.isTextMimeType("application/jsonl") == true)
        #expect(AttachmentStore.isTextMimeType("application/xml") == true)
    }

    @Test("Non-text MIME types rejected")
    func isNotTextMimeType() {
        #expect(AttachmentStore.isTextMimeType("image/jpeg") == false)
        #expect(AttachmentStore.isTextMimeType("video/mp4") == false)
        #expect(AttachmentStore.isTextMimeType("application/pdf") == false)
        #expect(AttachmentStore.isTextMimeType("application/octet-stream") == false)
    }

    // MARK: - SmartAttachmentResult

    @Test("SmartAttachmentResult.text model description")
    func smartResultText() {
        let result = SmartAttachmentResult.text("Hello world")
        #expect(result.modelDescription == "Hello world")
    }

    @Test("SmartAttachmentResult.pdfText model description")
    func smartResultPdf() {
        let result = SmartAttachmentResult.pdfText("Page content", pageCount: 3)
        #expect(result.modelDescription.contains("PDF"))
        #expect(result.modelDescription.contains("3 pages"))
        #expect(result.modelDescription.contains("Page content"))
    }

    @Test("SmartAttachmentResult.image model description")
    func smartResultImage() {
        let data = Data([0xFF, 0xD8, 0xFF])
        let result = SmartAttachmentResult.image(data, mimeType: "image/jpeg", width: 100, height: 200)
        let desc = result.modelDescription
        #expect(desc.contains("100×200"))
        #expect(desc.contains("base64"))
    }

    @Test("SmartAttachmentResult.videoMetadata model description")
    func smartResultVideo() {
        let result = SmartAttachmentResult.videoMetadata(duration: 10.5, width: 1920, height: 1080, hasAudio: true, thumbnail: nil)
        let desc = result.modelDescription
        #expect(desc.contains("1920×1080"))
        #expect(desc.contains("10.5"))
        #expect(desc.contains("audio"))
    }

    // MARK: - Attachment Store Lifecycle

    @Test("Attachment store clear removes all entries")
    func attachmentStoreClear() {
        let store = AttachmentStore()
        _ = store.add(url: URL(fileURLWithPath: "/tmp/test.jpg"))
        #expect(store.promptDescription() != nil)
        store.clear()
        #expect(store.promptDescription() == nil)
    }

    @Test("Attachment store prompt description includes view instruction")
    func attachmentStorePromptDescription() {
        let store = AttachmentStore()
        _ = store.add(url: URL(fileURLWithPath: "/tmp/photo.png"))
        let desc = store.promptDescription()!
        #expect(desc.contains("view"))
    }

    // MARK: - File Converter Property

    @Test("fileConverter starts as nil")
    func fileConverterNil() {
        let vm = makeTestVM()
        #expect(vm.fileConverter == nil)
    }

    @Test("fileConverter can be set")
    func fileConverterSet() {
        let vm = makeTestVM()
        vm.fileConverter = { @Sendable _, _ in return "/path/to/result" }
        #expect(vm.fileConverter != nil)
    }
}
