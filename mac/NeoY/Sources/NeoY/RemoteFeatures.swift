import Foundation

enum NeoYRemoteToolCatalog {
    static let coreToolNames: Set<String> = [
        "setup", "cluster", "status", "shell", "fs", "apply_patch",
        "codex", "audit_tail", "terminal", "chatgpt",
    ]

    static func availableToolNames(configuration: NeoYControlPlaneConfiguration) -> [String] {
        var names = coreToolNames
        if configuration.capabilities.isEnabled(.accessibilityComputer) { names.insert("computer") }
        if configuration.capabilities.isEnabled(.demoRecording) { names.insert("demo") }
        if configuration.capabilities.isEnabled(.captureTour) { names.insert("tour") }
        if configuration.capabilities.isEnabled(.phoneIntegration) { names.insert("phone") }
        return names.sorted()
    }

    /// One-time migration from the old feature buckets to exact public tool names.
    static func migrateLegacyFeatures(_ features: Set<String>) -> Set<String> {
        var tools: Set<String> = []
        for feature in features {
            switch feature {
            case "setup": tools.insert("setup")
            case "terminal": tools.formUnion(["status", "audit_tail", "shell", "terminal"])
            case "files": tools.formUnion(["fs", "apply_patch"])
            case "codex": tools.insert("codex")
            case "nodes": tools.insert("cluster")
            case "computer": tools.insert("computer")
            case "demo": tools.insert("demo")
            case "tour": tools.insert("tour")
            case "phone": tools.insert("phone")
            case "mcp-services": break
            default:
                // Already an exact tool name from a newer config.
                tools.insert(feature)
            }
        }
        return tools
    }
}
