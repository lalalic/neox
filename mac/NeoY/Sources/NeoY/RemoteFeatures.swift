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
        case .mcpServices: "Connected MCP Services"
        }
    }

    func matches(toolName: String) -> Bool {
        switch self {
        case .setup: toolName == "setup"
        case .terminal: toolName == "bridge_status" || toolName == "audit_tail" || toolName == "shell" || toolName == "terminal"
        case .files: toolName == "fs" || toolName == "apply_patch"
        case .codex: toolName == "codex"
        case .nodes: toolName == "cluster"
        case .computer: toolName == "computer"
        case .demo: toolName == "demo"
        case .tour: toolName == "tour"
        case .phone: toolName == "phone"
        case .mcpServices: toolName == "events" || toolName.hasPrefix("mcp.")
        }
    }
}
