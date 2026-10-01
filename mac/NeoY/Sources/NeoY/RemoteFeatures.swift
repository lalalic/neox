import Foundation

enum NeoYRemoteFeature: String, CaseIterable, Identifiable, Codable, Sendable {
    case setup
    case terminal
    case files
    case codex
    case nodes
    case computer
    case demo
    case tour
    case phone
    case tutor
    case events
    case mcpServices = "mcp-services"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: "Setup"
        case .terminal: "Terminal"
        case .files: "Files"
        case .codex: "Codex"
        case .nodes: "Other Macs"
        case .computer: "Screen & Computer Control"
        case .demo: "Demo Recording"
        case .tour: "Capture Tour"
        case .phone: "Phone"
        case .tutor: "Family Tutor"
        case .events: "Events Bus"
        case .mcpServices: "Connected MCP Services"
        }
    }

    func matches(toolName: String) -> Bool {
        switch self {
        case .setup: toolName == "neoy.setup" || toolName == "feature.bootstrap"
        case .terminal: toolName == "mac.exec"
        case .files: toolName == "mac.fs"
        case .codex: toolName == "codex.threads"
        case .nodes: toolName == "node"
        case .computer: toolName.hasPrefix("computer.") || toolName.hasPrefix("accessibility.")
        case .demo: toolName.hasPrefix("demo.")
        case .tour: toolName.hasPrefix("tour.")
        case .phone: toolName.hasPrefix("phone.")
        case .tutor: toolName.hasPrefix("tutor.")
        case .events: toolName.hasPrefix("events.")
        case .mcpServices: toolName.hasPrefix("mcp.")
        }
    }
}
