import Foundation

enum NeoYCoreRuntime {
    static var version: String { version(in: .main) }

    static func version(in bundle: Bundle) -> String {
        version(in: bundle.infoDictionary ?? [:])
    }

    static func version(in infoDictionary: [String: Any]) -> String {
        infoDictionary["CFBundleShortVersionString"] as? String
            ?? infoDictionary["CFBundleVersion"] as? String
            ?? "Unknown"
    }
    static let toolNames: Set<String> = [
        "setup", "cluster", "status", "shell", "fs", "apply_file_patch",
        "codex", "terminal", "chatgpt"
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
