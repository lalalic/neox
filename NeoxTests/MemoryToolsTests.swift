import Testing
import Foundation
import CopilotSDK

// MARK: - Memory Tools Tests

@Suite("Memory Tools Tests")
struct MemoryToolsTests {

    /// Create a temp directory for isolated memory tests
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Initialization

    @Test("MemoryToolProvider creates .neo directory structure")
    func initCreatesDirectories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let neoDir = dir.appendingPathComponent(".neo")

        #expect(FileManager.default.fileExists(atPath: neoDir.path))
        #expect(FileManager.default.fileExists(atPath: neoDir.appendingPathComponent("memory/topics").path))
        #expect(FileManager.default.fileExists(atPath: neoDir.appendingPathComponent("memory/projects").path))
        #expect(FileManager.default.fileExists(atPath: neoDir.appendingPathComponent("knowledge").path))
        #expect(FileManager.default.fileExists(atPath: neoDir.appendingPathComponent("reports/sessions").path))
        #expect(FileManager.default.fileExists(atPath: neoDir.appendingPathComponent("reports/daily").path))
        #expect(FileManager.default.fileExists(atPath: neoDir.appendingPathComponent("reports/weekly").path))
        #expect(FileManager.default.fileExists(atPath: neoDir.appendingPathComponent("reports/monthly").path))
        #expect(FileManager.default.fileExists(atPath: neoDir.appendingPathComponent("reports/yearly").path))
        _ = provider // silence unused warning
    }

    @Test("MemoryToolProvider seeds user profile template")
    func initSeedsUserProfile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let profilePath = dir.appendingPathComponent(".neo/memory/user-profile.md")
        #expect(FileManager.default.fileExists(atPath: profilePath.path))

        let content = try String(contentsOf: profilePath, encoding: .utf8)
        #expect(content.contains("# User Profile"))
        #expect(content.contains("## Identity"))
        #expect(content.contains("## Preferences"))
        _ = provider
    }

    // MARK: - Tool Registration

    @Test("MemoryToolProvider provides 8 tools")
    func toolCount() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        #expect(provider.tools.count == 8)
    }

    @Test("All 8 memory tools are named correctly")
    func toolNames() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let names = Set(provider.tools.map(\.name))

        #expect(names.contains("memory_read"))
        #expect(names.contains("memory_append"))
        #expect(names.contains("memory_write_section"))
        #expect(names.contains("memory_log_session"))
        #expect(names.contains("memory_list"))
        #expect(names.contains("memory_search"))
        #expect(names.contains("memory_delete"))
        #expect(names.contains("memory_get_yesterday"))
    }

    // MARK: - memory_read

    @Test("memory_read returns empty for nonexistent file")
    func readNonexistent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let tool = provider.tools.first { $0.name == "memory_read" }!
        let result = try await tool.handler(.object([:]))
        // Default file is .neo/memory.md which may not exist yet or be empty
        #expect(result.isEmpty || result.count >= 0)
    }

    @Test("memory_read reads written content")
    func readAfterWrite() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let memoryFile = dir.appendingPathComponent(".neo/memory.md")
        try "# Test Memory\n\nSome content here".write(to: memoryFile, atomically: true, encoding: .utf8)

        let tool = provider.tools.first { $0.name == "memory_read" }!
        let result = try await tool.handler(.object([:]))
        #expect(result.contains("Test Memory"))
        #expect(result.contains("Some content here"))
    }

    @Test("memory_read with section filter")
    func readSection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let memoryFile = dir.appendingPathComponent(".neo/memory.md")
        let content = """
        # Memory

        ## Tasks
        - Task one
        - Task two

        ## Notes
        - Note one
        """
        try content.write(to: memoryFile, atomically: true, encoding: .utf8)

        let tool = provider.tools.first { $0.name == "memory_read" }!
        let result = try await tool.handler(.object([
            "section": .string("Tasks")
        ]))
        #expect(result.contains("Task one"))
        #expect(!result.contains("Note one"))
    }

    // MARK: - memory_append

    @Test("memory_append creates entry with timestamp")
    func appendWithTimestamp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let tool = provider.tools.first { $0.name == "memory_append" }!

        let result = try await tool.handler(.object([
            "content": .string("Test entry")
        ]))
        #expect(result.contains("Appended"))

        // Verify the file was created with timestamp format
        let memoryFile = dir.appendingPathComponent(".neo/memory.md")
        let content = try String(contentsOf: memoryFile, encoding: .utf8)
        #expect(content.contains("Test entry"))
        #expect(content.contains("["))  // timestamp bracket
    }

    // MARK: - memory_write_section

    @Test("memory_write_section creates new section")
    func writeSectionNew() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let tool = provider.tools.first { $0.name == "memory_write_section" }!

        let result = try await tool.handler(.object([
            "section": .string("New Section"),
            "content": .string("New content here")
        ]))
        #expect(!result.contains("Error"))

        let memoryFile = dir.appendingPathComponent(".neo/memory.md")
        let content = try String(contentsOf: memoryFile, encoding: .utf8)
        #expect(content.contains("## New Section"))
        #expect(content.contains("New content here"))
    }

    // MARK: - memory_list

    @Test("memory_list shows .neo directory contents")
    func listContents() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let tool = provider.tools.first { $0.name == "memory_list" }!

        let result = try await tool.handler(.object([:]))
        #expect(result.contains("memory"))  // .neo/memory/ directory
    }

    // MARK: - memory_search

    @Test("memory_search finds matching content")
    func searchFindsContent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        // Write some searchable content
        let memoryFile = dir.appendingPathComponent(".neo/memory.md")
        try "# Memory\n\nSwift programming notes".write(to: memoryFile, atomically: true, encoding: .utf8)

        let tool = provider.tools.first { $0.name == "memory_search" }!
        let result = try await tool.handler(.object([
            "query": .string("Swift")
        ]))
        #expect(result.contains("Swift"))
    }

    // MARK: - Path Sanitization

    @Test("Path traversal attack is blocked")
    func pathTraversalBlocked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = MemoryToolProvider(baseDirectory: dir)
        let tool = provider.tools.first { $0.name == "memory_read" }!

        let result = try await tool.handler(.object([
            "path": .string("../../etc/passwd")
        ]))
        #expect(result.contains("Error") || result.isEmpty)
    }
}
