import Testing
import Foundation
@testable import SwiftAgent

@Suite("Planner")
struct PlannerTests {

    @Test("Simple messages don't need planning")
    func simpleNoPlanning() async {
        let llm = MockLLMBackend()
        let planner = Planner(llm: llm)
        #expect(!planner.needsPlanning("What time is it?", availableTools: []))
        #expect(!planner.needsPlanning("Hello", availableTools: []))
    }

    @Test("Complex messages need planning")
    func complexNeedsPlanning() async {
        let llm = MockLLMBackend()
        let planner = Planner(llm: llm)
        #expect(planner.needsPlanning("Tóm tắt cuộc họp hôm qua và tạo nhắc nhở cho tất cả action items", availableTools: []))
        #expect(planner.needsPlanning("Search the meeting and then create a calendar event", availableTools: []))
    }

    @Test("Multi-question messages need planning")
    func multiQuestion() async {
        let llm = MockLLMBackend()
        let planner = Planner(llm: llm)
        #expect(planner.needsPlanning("Ai tham gia cuộc họp? Quyết định gì? Deadline là khi nào?", availableTools: []))
    }

    @Test("Plan step lifecycle")
    func planStepLifecycle() {
        var step = PlanStep(index: 0, thought: "Need to search", action: "Search meetings", toolName: "search_meetings")
        #expect(step.status == .pending)
        step.status = .executing
        #expect(step.status == .executing)
        step.status = .completed
        step.result = "Found 3 meetings"
        #expect(step.result == "Found 3 meetings")
    }

    @Test("Plan progress calculation")
    func planProgress() {
        var plan = Plan(goal: "test", steps: [
            PlanStep(index: 0, thought: "", action: "step 1"),
            PlanStep(index: 1, thought: "", action: "step 2"),
            PlanStep(index: 2, thought: "", action: "step 3"),
            PlanStep(index: 3, thought: "", action: "step 4"),
        ])
        #expect(plan.progress == 0)

        plan.steps[0].status = .completed
        plan.steps[1].status = .completed
        #expect(plan.progress == 0.5)

        plan.steps[2].status = .skipped
        plan.steps[3].status = .completed
        #expect(plan.progress == 1.0)
    }

    @Test("Plan execution with tool executor")
    func planExecution() async {
        let llm = MockLLMBackend()
        let planner = Planner(llm: llm)

        let plan = Plan(goal: "Test plan", steps: [
            PlanStep(index: 0, thought: "Check time", action: "Get time", toolName: "get_datetime"),
            PlanStep(index: 1, thought: "Calculate", action: "Do math", toolName: "calculate"),
        ])

        let executed = await planner.executePlan(plan) { toolName, params in
            return .success("Result for \(toolName)")
        }

        #expect(executed.status == .completed)
        #expect(executed.steps[0].status == .completed)
        #expect(executed.steps[1].status == .completed)
    }

    @Test("Plan execution handles step failure gracefully")
    func planFailureRecovery() async {
        let llm = MockLLMBackend()
        let planner = Planner(llm: llm)

        let plan = Plan(goal: "Test failure", steps: [
            PlanStep(index: 0, thought: "Will fail", action: "Fail step", toolName: "bad_tool"),
            PlanStep(index: 1, thought: "Should still run", action: "Good step", toolName: "good_tool"),
        ])

        let executed = await planner.executePlan(plan) { toolName, params in
            if toolName == "bad_tool" { return .error("Tool not found") }
            return .success("OK")
        }

        #expect(executed.status == .partiallyCompleted) // not .failed
        #expect(executed.steps[0].status == .failed)
        #expect(executed.steps[1].status == .completed)
    }

    @Test("Plan and PlanStep are codable")
    func codable() throws {
        let plan = Plan(goal: "test", steps: [
            PlanStep(index: 0, thought: "think", action: "act", toolName: "tool")
        ])
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(Plan.self, from: data)
        #expect(decoded.goal == "test")
        #expect(decoded.steps.count == 1)
        #expect(decoded.steps[0].toolName == "tool")
    }
}
