import Foundation

/// Self-test surface: lets the desktop agent exercise the phone→bridge path
/// (Bonjour discovery + POST) end-to-end without Siri or Shortcuts. Deliberately
/// outside the media workflow — see the neox-phone-mcp skill's bridge recipe.
enum DebugTools {

    static func tools() -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "agent.handoff",
                description: "Self-test the agent-bridge path: the phone resolves the _neox-agent._tcp Bonjour service and POSTs the Run Agent Task handoff message to it. Returns posted / bridgeNotFound / error. Use after starting the desktop bridge to verify reachability from the phone.",
                parameters: MediaTools.schema([
                    "instruction": MediaTools.stringProp("Instruction text to hand off (default: the standard vlog instruction)"),
                ]),
                handler: { args in
                    let instruction = MediaTools.str(args, "instruction") ?? AgentHandoff.defaultInstruction
                    let mcpURL = await MainActor.run { ServerController.shared.mcpURL }
                    let message = AgentHandoff.message(instruction: instruction, mcpURL: mcpURL)
                    switch await AgentBridge.handoff(message) {
                    case .posted:
                        return "posted to bridge"
                    case .bridgeNotFound:
                        return "Error: no _neox-agent._tcp bridge advertised on the LAN"
                    case .failed(let why):
                        return "Error: \(why)"
                    }
                }
            ),
        ]
    }
}
