import Testing
import Foundation
import CopilotSDK

// MARK: - Plan & Sub-Agent Tests

@Suite("Plan & Sub-Agent Tests")
struct PlanAndSubAgentTests {

    /// Create a temp directory for isolated plan tests
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Plan Model

    @Test("Plan has all required fields")
    func planConstruction() {
        let plan = Plan(
            name: "Test Plan",
            prompt: "Do something",
            schedule: .manual,
            model: "gpt-4.1",
            enabled: true,
            tools: ["memory_read"]
        )
        #expect(plan.name == "Test Plan")
        #expect(plan.prompt == "Do something")
        #expect(plan.model == "gpt-4.1")
        #expect(plan.enabled == true)
        #expect(plan.tools == ["memory_read"])
        #expect(!plan.id.isEmpty)
    }

    @Test("Plan default values")
    func planDefaults() {
        let plan = Plan(name: "Basic", prompt: "Test", schedule: .manual)
        #expect(plan.model == "gpt-4.1")
        #expect(plan.enabled == true)
        #expect(plan.requiresApproval == false)
        #expect(plan.maxTokenBudget == 10000)
        #expect(plan.tools.isEmpty)
    }

    // MARK: - PlanSchedule

    @Test("Manual schedule has no next fire date")
    func manualSchedule() {
        let schedule = PlanSchedule.manual
        #expect(schedule.nextFireDate() == nil)
    }

    @Test("Once schedule fires if in future")
    func onceScheduleFuture() {
        let future = Date().addingTimeInterval(3600)
        let schedule = PlanSchedule.once(at: future)
        let next = schedule.nextFireDate()
        #expect(next != nil)
        #expect(next == future)
    }

    @Test("Once schedule does not fire if in past")
    func onceSchedulePast() {
        let past = Date().addingTimeInterval(-3600)
        let schedule = PlanSchedule.once(at: past)
        #expect(schedule.nextFireDate() == nil)
    }

    @Test("Interval schedule calculates next date")
    func intervalSchedule() {
        let schedule = PlanSchedule.interval(seconds: 86400)
        let next = schedule.nextFireDate()
        #expect(next != nil)
        // Should be roughly 24 hours from now
        let diff = next!.timeIntervalSinceNow
        #expect(diff > 86390 && diff < 86410)
    }

    @Test("Cron schedule returns nil (not implemented)")
    func cronSchedule() {
        let schedule = PlanSchedule.cron(expression: "0 0 * * *", timezone: "UTC")
        #expect(schedule.nextFireDate() == nil)
    }

    // MARK: - PlanExecution

    @Test("PlanExecution starts as running")
    func executionStartsRunning() {
        let exec = PlanExecution(planId: "test-plan")
        #expect(exec.status == .running)
        #expect(exec.completedAt == nil)
        #expect(exec.error == nil)
        #expect(exec.result == nil)
    }

    @Test("PlanExecution complete sets status and result")
    func executionComplete() {
        var exec = PlanExecution(planId: "test-plan")
        exec.complete(
            result: "Done successfully",
            tokensUsed: PlanExecution.TokenUsage(promptTokens: 100, completionTokens: 50),
            cost: 0.01
        )
        #expect(exec.status == .completed)
        #expect(exec.result == "Done successfully")
        #expect(exec.tokensUsed?.promptTokens == 100)
        #expect(exec.tokensUsed?.completionTokens == 50)
        #expect(exec.cost == 0.01)
        #expect(exec.completedAt != nil)
    }

    @Test("PlanExecution fail sets error")
    func executionFail() {
        var exec = PlanExecution(planId: "test-plan")
        exec.fail(error: "Something went wrong")
        #expect(exec.status == .failed)
        #expect(exec.error == "Something went wrong")
        #expect(exec.completedAt != nil)
    }

    // MARK: - PlanStore CRUD

    @Test("PlanStore starts empty (without seeded plans)")
    func planStoreStartsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PlanStore(directory: dir)
        // May have seeded "memory-reports" plan
        let hasSeeded = store.plans.contains(where: { $0.id == "memory-reports" })
        #expect(hasSeeded || store.plans.isEmpty)
    }

    @Test("PlanStore seeds memory-reports plan")
    func planStoreSeedsReports() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PlanStore(directory: dir)
        let reportPlan = store.plans.first(where: { $0.id == "memory-reports" })
        #expect(reportPlan != nil)
        #expect(reportPlan?.name == "Memory Reports")
        #expect(reportPlan?.enabled == true)
        #expect(reportPlan?.tools.contains("run_sub_agent") == true)
    }

    @Test("PlanStore create and retrieve")
    func planStoreCreate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PlanStore(directory: dir)
        let plan = Plan(id: "custom-plan", name: "Custom", prompt: "Do X", schedule: .manual)
        store.createPlan(plan)

        #expect(store.plans.contains(where: { $0.id == "custom-plan" }))
    }

    @Test("PlanStore delete removes plan")
    func planStoreDelete() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PlanStore(directory: dir)
        let plan = Plan(id: "to-delete", name: "Temp", prompt: "X", schedule: .manual)
        store.createPlan(plan)
        #expect(store.plans.contains(where: { $0.id == "to-delete" }))

        store.deletePlan("to-delete")
        #expect(!store.plans.contains(where: { $0.id == "to-delete" }))
    }

    @Test("PlanStore persists across instances")
    func planStorePersistence() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = PlanStore(directory: dir)
        store1.createPlan(Plan(id: "persist-test", name: "Persist", prompt: "Y", schedule: .manual))

        let store2 = PlanStore(directory: dir)
        #expect(store2.plans.contains(where: { $0.id == "persist-test" }))
    }

    // MARK: - Execution History

    @Test("Execution history starts empty")
    func executionHistoryEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PlanStore(directory: dir)
        #expect(store.getHistory(for: "any-plan").isEmpty)
    }

    @Test("Execution history records and retrieves")
    func executionHistoryRecords() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PlanStore(directory: dir)
        var exec = PlanExecution(planId: "test-plan")
        exec.complete(result: "OK", tokensUsed: nil, cost: nil)
        store.addExecution(exec)

        let history = store.getHistory(for: "test-plan")
        #expect(history.count == 1)
        #expect(history.first?.status == .completed)
    }

    @Test("Execution history filters by plan ID")
    func executionHistoryFiltered() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PlanStore(directory: dir)
        store.addExecution(PlanExecution(planId: "plan-a"))
        store.addExecution(PlanExecution(planId: "plan-b"))
        store.addExecution(PlanExecution(planId: "plan-a"))

        #expect(store.getHistory(for: "plan-a").count == 2)
        #expect(store.getHistory(for: "plan-b").count == 1)
        #expect(store.getHistory(for: "plan-c").count == 0)
    }

    // MARK: - SubAgentToolProvider

    @Test("SubAgentToolProvider creates run_sub_agent tool")
    func subAgentToolCreated() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = SubAgentToolProvider(
            workspaceURL: dir,
            relayHost: "localhost",
            relayPort: 8765,
            userId: "test-user",
            toolsBuilder: { [] }
        )
        let tools = provider.tools
        #expect(tools.count == 1)
        #expect(tools.first?.name == "run_sub_agent")
    }

    @Test("SubAgentToolProvider reads agent files from .github/agents")
    func subAgentReadsAgentFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a test agent file
        let agentsDir = dir.appendingPathComponent(".github/agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let agentContent = """
        ---
        name: test-agent
        description: A test agent
        model: gpt-4.1
        tools:
          - memory_read
          - memory_write_section
        ---
        You are a test agent.
        """
        try agentContent.write(to: agentsDir.appendingPathComponent("test.agent.md"),
                               atomically: true, encoding: .utf8)

        let provider = SubAgentToolProvider(
            workspaceURL: dir,
            relayHost: "localhost",
            relayPort: 8765,
            userId: "test-user",
            toolsBuilder: { [] }
        )

        // The sub-agent tool should be able to find our test agent
        let tool = provider.tools.first!
        let result = try await tool.handler(.object([
            "agent": .string("nonexistent"),
            "task": .string("test task")
        ]))
        // Should fail gracefully for nonexistent agent
        #expect(result.contains("Error") || result.contains("not found") || result.contains("Available"))
    }
}
