import Foundation

enum NeoYCoreRuntime {
    static let version = "2.3.0"
    static let toolNames: Set<String> = [
        "setup", "cluster", "status", "shell", "fs", "apply_patch",
        "codex", "audit_tail", "terminal"
    ]

    @MainActor
    static func register(
        on server: MCPServer,
        setup: NeoYSetupService,
        node: NeoYNodeService
    ) {
        server.register(tools: NeoYSetupTools.tools(service: setup), protected: true)
        server.register(tools: NeoYNodeTools.tools(service: node), protected: true)
    }
}
