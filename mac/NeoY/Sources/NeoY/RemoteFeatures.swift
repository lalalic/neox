import Foundation

enum NeoYRemoteToolCatalog {
    static let coreToolNames: Set<String> = [
        "setup", "cluster", "status", "shell", "fs", "apply_file_patch",
        "codex", "terminal", "chatgpt",
    ]

    static let askQuestionsToolNames: Set<String> = [
        "ask_questions",
    ]

    // Native capabilities are the only MCP tools in this catalog with a
    // supported global enable/disable contract. Core tools stay Core-owned.
    static let nativeOptionalTools: [String: NeoYOptionalCapability] = [
        "computer": .accessibilityComputer,
        "demo": .demoRecording,
        "tour": .captureTour,
        "phone": .phoneIntegration,
        "ask_questions": .askQuestions,
    ]

    static func availableToolNames(configuration: NeoYControlPlaneConfiguration) -> [String] {
        var names = coreToolNames
        if configuration.capabilities.isEnabled(.askQuestions) { names.formUnion(askQuestionsToolNames) }
        if configuration.capabilities.isEnabled(.accessibilityComputer) { names.insert("computer") }
        if configuration.capabilities.isEnabled(.demoRecording) { names.insert("demo") }
        if configuration.capabilities.isEnabled(.captureTour) { names.insert("tour") }
        if configuration.capabilities.isEnabled(.phoneIntegration) { names.insert("phone") }
        if !configuration.capabilities.disabledTools.contains("voice.reply") && !configuration.capabilities.disabledTools.contains("voice.session") { names.insert("voice.reply") }
        return names.sorted()
    }

    /// App-only helpers are usable remotely only with their parent intent.
    static func remoteTools(for tools: Set<String>) -> Set<String> {
        return tools.subtracting(["ask_questions.submit", "ask_questions.cancel"])
    }

    /// Normalize persisted tool selections when Core renames or removes tools.
    static func normalizeToolNames(_ tools: Set<String>) -> Set<String> {
        var normalized = tools.subtracting(["audit_tail", "apply_patch", "git_apply_patch", "ask_questions.submit", "ask_questions.cancel"])
        if !tools.isDisjoint(with: ["apply_patch", "git_apply_patch"]) { normalized.insert("apply_file_patch") }
        return normalized
    }

    /// One-time migration from the old feature buckets to exact public tool names.
    static func migrateLegacyFeatures(_ features: Set<String>) -> Set<String> {
        var tools: Set<String> = []
        for feature in features {
            switch feature {
            case "setup": tools.insert("setup")
            case "terminal": tools.formUnion(["status", "shell", "terminal"])
            case "files": tools.formUnion(["fs", "apply_file_patch"])
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
        return normalizeToolNames(tools)
    }
}
