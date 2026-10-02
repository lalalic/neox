import Foundation

enum NeoYRemoteFeature: String, CaseIterable, Identifiable, Codable, Sendable {
    case setup
    case computer
    case demo
    case tour
    case phone
    case mcpServices = "mcp-services"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: "Setup"
        case .computer: "Screen & Computer Control"
        case .demo: "Demo Recording"
        case .tour: "Capture Tour"
        case .phone: "Phone"
        case .mcpServices: "Connected MCP Services"
        }
    }

    func matches(toolName: String) -> Bool {
        switch self {
        case .setup: toolName == "neoy.setup"
        case .computer: toolName.hasPrefix("computer.") || toolName.hasPrefix("accessibility.")
        case .demo: toolName.hasPrefix("demo.")
        case .tour: toolName.hasPrefix("tour.")
        case .phone: toolName.hasPrefix("phone.")
        case .mcpServices: toolName.hasPrefix("mcp.")
        }
    }
}
