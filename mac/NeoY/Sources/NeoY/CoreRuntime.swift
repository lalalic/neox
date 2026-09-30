import Foundation

enum NeoYCoreRuntime {
    static let version = "2.2.1"
    static let toolNames: Set<String> = [
        "neoy.setup",
        "mac.exec",
        "mac.fs",
        "codex.threads",
        "node"
    ]

    @MainActor
    static func register(
        on server: MCPServer,
        setup: NeoYSetupService,
        exec: NeoYExecService,
        files: NeoYCoreFileService,
        codex: NeoYCodexThreadService,
        node: NeoYNodeService
    ) {
        server.register(tools: NeoYSetupTools.tools(service: setup), protected: true)
        server.register(tools: NeoYExecTools.tools(service: exec), protected: true)
        server.register(tools: NeoYFileTools.tools(service: files), protected: true)
        server.register(tools: NeoYCodexThreadTools.tools(service: codex), protected: true)
        server.register(tools: NeoYNodeTools.tools(service: node), protected: true)
    }
}
