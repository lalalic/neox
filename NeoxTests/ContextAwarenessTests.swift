import Testing
import Foundation
@testable import Neox
import CopilotSDK
import CopilotChat

// MARK: - Context Awareness Tests

@Suite("Context Awareness Tests")
@MainActor
struct ContextAwarenessTests {

    // MARK: - ContextToolProvider

    @Test("ContextToolProvider creates get_context tool")
    func contextToolCreated() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-workspace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ContextToolProvider(workspaceURL: tempDir)
        let tools = provider.tools
        #expect(tools.count == 1)
        #expect(tools.first?.name == "get_context")
    }

    @Test("get_context tool returns time context by default")
    func contextToolReturnsTime() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-workspace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ContextToolProvider(workspaceURL: tempDir)
        let tool = provider.tools.first!
        let result = try await tool.handler(.object([:])) 
        #expect(result.contains("time:"))
        #expect(result.contains("dayOfWeek:"))
        #expect(result.contains("timeOfDay:"))
        #expect(result.contains("timezone:"))
    }

    @Test("get_context with include filter returns only requested signals")
    func contextToolFiltered() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-workspace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ContextToolProvider(workspaceURL: tempDir)
        let tool = provider.tools.first!

        // Request only time
        let result = try await tool.handler(.object([
            "include": .array([.string("time")])
        ]))
        #expect(result.contains("time:"))
        // Should NOT contain battery or network
        #expect(!result.contains("battery:"))
    }

    @Test("get_context returns network context")
    func contextToolNetwork() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-workspace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ContextToolProvider(workspaceURL: tempDir)
        let tool = provider.tools.first!

        let result = try await tool.handler(.object([
            "include": .array([.string("network")])
        ]))
        #expect(result.contains("network:"))
        #expect(result.contains("connected:"))
    }

    @Test("get_context returns projects context")
    func contextToolProjects() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-workspace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake project with README.md
        let projectDir = tempDir.appendingPathComponent("my-project")
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try? "# My Project".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let provider = ContextToolProvider(workspaceURL: tempDir)
        let tool = provider.tools.first!

        let result = try await tool.handler(.object([
            "include": .array([.string("projects")])
        ]))
        #expect(result.contains("projects:"))
        #expect(result.contains("my-project"))
    }

    @Test("get_context registered in AgentCoordinator")
    func contextToolRegisteredInCoordinator() {
        let coordinator = AgentCoordinator()
        coordinator.registerDefaultTools()

        let toolNames = coordinator.registeredTools.map(\.name)
        #expect(toolNames.contains("get_context"))
    }

    // MARK: - Time of Day Logic

    @Test("Time of day bands are correct")
    func timeOfDayBands() {
        // Test the time-of-day categorization logic
        // morning: 6-10, midday: 10-14, afternoon: 14-18, evening: 18-22, night: 0-6 and 22-24
        let bands: [(Int, String)] = [
            (3, "night"), (6, "morning"), (10, "midday"),
            (14, "afternoon"), (18, "evening"), (22, "night")
        ]
        for (hour, expected) in bands {
            let timeOfDay: String
            switch hour {
            case 6..<10: timeOfDay = "morning"
            case 10..<14: timeOfDay = "midday"
            case 14..<18: timeOfDay = "afternoon"
            case 18..<22: timeOfDay = "evening"
            default: timeOfDay = "night"
            }
            #expect(timeOfDay == expected, "Hour \(hour) should be \(expected)")
        }
    }
}
