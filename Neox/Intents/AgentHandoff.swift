import Foundation

/// The single place where the handoff message to the agent is composed.
///
/// The intent is a courier: it contributes the user's instruction plus this
/// phone's capability endpoint. All reasoning (dates, "yesterday", which
/// media to use) happens in the agent session — never here. Transport to the
/// Mac is Codex Remote's job.
enum AgentHandoff {
    /// Default instruction backing the fixed Siri phrases ("Create a vlog with Neox").
    static let defaultInstruction = "Create a vlog from yesterday's photos and videos"

    static func message(instruction: String, mcpURL: String) -> String {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(instruction)

        iPhone media MCP server: \(mcpURL)
        LAN only, no auth. Discover tools with tools/list first; inspect metadata \
        and thumbnails before exporting; stream originals from /files/ over HTTP — \
        never inline media in the chat.
        """
    }
}
