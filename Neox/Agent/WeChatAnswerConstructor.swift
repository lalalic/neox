import Foundation
import CopilotChat

/// Collects and synthesizes multiple WeChat responses to a pending `ask_questions`.
/// For multi-party rooms, waits for sufficient input before constructing a final answer.
/// For 1:1 chats, resolves immediately with the single response.
@MainActor
final class WeChatAnswerConstructor {

    struct PendingAnswer {
        let question: String
        /// Responses collected so far.
        var responses: [(sender: String, weight: Int, text: String, time: Date)]
        let startTime: Date
        let timeout: TimeInterval

        var isTimedOut: Bool {
            Date().timeIntervalSince(startTime) >= timeout
        }
    }

    enum Result {
        case waiting(reason: String)
        case ready(answer: String)
    }

    /// Active pending answers per project.
    private var pending: [String: PendingAnswer] = [:]

    /// Timeout timers per project.
    private var timers: [String: Task<Void, Never>] = [:]

    private weak var coordinator: AgentCoordinator?
    private var onTimeout: ((_ projectId: String, _ answer: String) async -> Void)?

    /// Default collection timeout (5 minutes).
    static let defaultTimeout: TimeInterval = 300

    init(coordinator: AgentCoordinator, onTimeout: ((_ projectId: String, _ answer: String) async -> Void)? = nil) {
        self.coordinator = coordinator
        self.onTimeout = onTimeout
    }

    /// Start collecting responses for a pending question.
    func startCollecting(projectId: String, question: String, timeout: TimeInterval = defaultTimeout) {
        pending[projectId] = PendingAnswer(
            question: question,
            responses: [],
            startTime: Date(),
            timeout: timeout
        )

        // Start timeout timer
        timers[projectId]?.cancel()
        timers[projectId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.handleTimeout(projectId: projectId)
        }
    }

    /// Add a response to a pending question. Returns .ready if we have enough to synthesize.
    func addResponse(
        projectId: String,
        sender: String,
        weight: Int,
        text: String,
        isRoom: Bool
    ) async -> Result {
        guard var pa = pending[projectId] else {
            // No pending answer — shouldn't happen, but treat as ready
            return .ready(answer: text)
        }

        pa.responses.append((sender: sender, weight: weight, text: text, time: Date()))
        pending[projectId] = pa

        // 1:1 mode: skip constructor, resolve immediately
        if !isRoom {
            resolve(projectId: projectId)
            return .ready(answer: text)
        }

        // Room mode: check readiness
        return await checkReadiness(projectId: projectId)
    }

    /// Check if we have enough responses to construct an answer.
    private func checkReadiness(projectId: String) async -> Result {
        guard let pa = pending[projectId] else { return .waiting(reason: "no pending") }

        // Fast paths (no LLM needed)

        // High-weight member gave clear answer → ready immediately
        if let highWeight = pa.responses.first(where: { $0.weight >= 100 }) {
            let answer = synthesizeLocal(pa)
            resolve(projectId: projectId)
            return .ready(answer: answer)
        }

        // Timed out → force resolve
        if pa.isTimedOut {
            let answer = synthesizeLocal(pa)
            resolve(projectId: projectId)
            return .ready(answer: answer)
        }

        // Only one response from a mid-weight member on a simple question → ready
        if pa.responses.count == 1, let first = pa.responses.first, first.weight >= 50 {
            // Simple question heuristic: short question text
            if pa.question.count < 100 {
                let answer = synthesizeLocal(pa)
                resolve(projectId: projectId)
                return .ready(answer: answer)
            }
        }

        // Multiple responses — use LLM to evaluate readiness
        if pa.responses.count >= 2 {
            return await evaluateWithLLM(projectId: projectId, pa: pa)
        }

        // Not enough data yet
        return .waiting(reason: "Waiting for more responses (have \(pa.responses.count))")
    }

    /// Use the wechat-answer-constructor agent to evaluate readiness.
    private func evaluateWithLLM(projectId: String, pa: PendingAnswer) async -> Result {
        guard let coordinator else {
            return .ready(answer: synthesizeLocal(pa))
        }

        var prompt = "Evaluate if we have enough responses to answer the pending question.\n\n"
        prompt += "**Question**: \(pa.question)\n\n"
        prompt += "**Responses collected**:\n"
        for r in pa.responses {
            prompt += "- \(r.sender) (weight: \(r.weight)): \(r.text)\n"
        }
        prompt += "\nElapsed: \(Int(Date().timeIntervalSince(pa.startTime)))s of \(Int(pa.timeout))s timeout\n"
        prompt += "\nIf ready, respond with: READY: <synthesized answer>\n"
        prompt += "If not ready, respond with: WAITING: <reason>"

        let result = await coordinator.runSubAgent(
            name: "wechat-answer-constructor",
            task: prompt,
            model: "gpt-4.1-mini"
        )

        if result.uppercased().hasPrefix("READY:") {
            let answer = String(result.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            resolve(projectId: projectId)
            return .ready(answer: answer)
        }

        return .waiting(reason: result)
    }

    /// Synthesize answer locally from responses (no LLM).
    private func synthesizeLocal(_ pa: PendingAnswer) -> String {
        if pa.responses.count == 1 {
            return pa.responses[0].text
        }

        // Sort by weight desc, concatenate
        let sorted = pa.responses.sorted { $0.weight > $1.weight }
        var parts: [String] = []
        for r in sorted {
            parts.append("\(r.sender) (w:\(r.weight)): \(r.text)")
        }
        return parts.joined(separator: "\n")
    }

    /// Clear pending state for a project.
    func resolve(projectId: String) {
        pending.removeValue(forKey: projectId)
        timers[projectId]?.cancel()
        timers.removeValue(forKey: projectId)
    }

    /// Handle timeout — force resolve with best available answer.
    private func handleTimeout(projectId: String) async {
        guard let pa = pending[projectId], !pa.responses.isEmpty else {
            resolve(projectId: projectId)
            return
        }

        let answer = synthesizeLocal(pa)
        resolve(projectId: projectId)
        await onTimeout?(projectId, answer)
    }

    /// Check if there's a pending answer collection for a project.
    func hasPending(for projectId: String) -> Bool {
        pending[projectId] != nil
    }
}
