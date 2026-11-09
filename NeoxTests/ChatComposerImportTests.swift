import XCTest
@testable import NeoxApp

final class ChatComposerImportTests: XCTestCase {
    func testAppendsRecognizedTextWithoutLosingDraft() {
        XCTAssertEqual(
            ChatComposerImport.append("  words from image  ", to: "Check this",
                                      source: "Photo text"),
            "Check this\n\n[Photo text]\nwords from image"
        )
        XCTAssertEqual(
            ChatComposerImport.append(" ", to: "unchanged", source: "Photo text"),
            "unchanged"
        )
    }

    func testImportTextRespectsGatewayLimit() {
        let draft = String(repeating: "A", count: 1990)
        let result = ChatComposerImport.append(
            String(repeating: "B", count: 200), to: draft, source: "note.txt"
        )
        XCTAssertEqual(result.count, 2000)
        XCTAssertTrue(result.hasPrefix(draft))
        XCTAssertEqual(ChatComposerImport.append("more", to: result, source: "x"), result)
    }

    func testReadsTextFileAndRejectsUnknownBinaryFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.txt")
        try Data("你好, Hello".utf8).write(to: text)
        XCTAssertEqual(try ChatComposerImport.textFromFile(text), "你好, Hello")

        let binary = folder.appendingPathComponent("unknown.bin")
        try Data([0x00, 0x01, 0xff]).write(to: binary)
        XCTAssertThrowsError(try ChatComposerImport.textFromFile(binary))
    }
}
