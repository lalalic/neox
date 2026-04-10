import Foundation
import CopilotChat

/// Classifies incoming WeChat messages using the wechat-router agent definition.
/// Decides: resolve_tool_call, new_input, or context_only.
@MainActor
final class WeChatRoutingAgent {

    enum Action: String {
        case resolveToolCall = "resolve_tool_call"
        case newInput = "new_input"
        case contextOnly = "context_only"
    }

    private weak var coordinator: AgentCoordinator?

    init(coordinator: AgentCoordinator) {
        self.coordinator = coordinator
    }

    /// Classify an incoming message.
    /// Returns the routing action. Falls back to .newInput on errors (better to over-process).
    func classify(
        message: String,
        sender: String,
        weight: Int,
        contactName: String,
        pendingQuestion: String?,
        recentHistory: [ChatLogEntry],
        agentState: String
    ) async -> Action {
        // Fast path: weight 0 = muted (should be filtered upstream, but safety)
        guard weight > 0 else { return .contextOnly }

        // Fast path: no pending question and simple heuristics
        if pendingQuestion == nil {
            // No pending question — it's either new_input or context_only
            // Use heuristic for very short/casual messages
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let casual = ["ok", "好", "嗯", "👍", "lol", "haha", "nice", "cool", "thx", "thanks", "谢谢", "了解"]
            if casual.contains(trimmed) && weight < 50 {
                return .contextOnly
            }
            // Default: new_input (better to over-process)
            if weight < 20 && trimmed.count < 10 {
                return .contextOnly
            }
        }

        // For messages with a pending question or more nuanced cases, use LLM classification
        guard let coordinator else { return .newInput }

        let prompt = buildClassificationPrompt(
            message: message,
            sender: sender,
            weight: weight,
            contactName: contactName,
            pendingQuestion: pendingQuestion,
            recentHistory: recentHistory,
            agentState: agentState
        )

        let result = await coordinator.runSubAgent(name: "wechat-router", task: prompt, model: "gpt-4.1-mini")

        return parseAction(result)
    }

    private func buildClassificationPrompt(
        message: String,
        sender: String,
        weight: Int,
        contactName: String,
        pendingQuestion: String?,
        recentHistory: [ChatLogEntry],
        agentState: String
    ) -> String {
        var prompt = "Classify this incoming WeChat message.\n\n"
        prompt += "**Message**: \(message)\n"
        prompt += "**Sender**: \(sender) (weight: \(weight))\n"
        prompt += "**Contact/Room**: \(contactName)\n"
        prompt += "**Agent state**: \(agentState)\n"

        if let pq = pendingQuestion {
            prompt += "**Pending ask_questions**: \(pq)\n"
        } else {
            prompt += "**Pending ask_questions**: none\n"
        }

        if !recentHistory.isEmpty {
            prompt += "\n**Recent history** (last \(recentHistory.count) messages):\n"
            for entry in recentHistory.suffix(10) {
                prompt += "- \(entry.sender) (w:\(entry.weight)): \(entry.text.prefix(100))\n"
            }
        }

        prompt += "\nRespond with EXACTLY one word: resolve_tool_call, new_input, or context_only"
        return prompt
    }

    private func parseAction(_ result: String) -> Action {
        let lower = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("resolve_tool_call") { return .resolveToolCall }
        if lower.contains("context_only") { return .contextOnly }
        // Default to new_input (better to over-process)
        return .newInput
    }
}
