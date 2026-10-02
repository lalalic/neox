import Foundation

enum NeoYCoreRuntime {
    static let version = "2.3.0"
    static let toolNames: Set<String> = ["neoy.setup"]

    @MainActor
    static func register(on server: MCPServer, setup: NeoYSetupService) {
        server.register(tools: NeoYSetupTools.tools(service: setup), protected: true)
    }
}
