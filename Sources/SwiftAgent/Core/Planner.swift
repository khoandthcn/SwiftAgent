import Foundation

// MARK: - Planning Module
//
// Inspired by CoPaw's task decomposition approach.
//
// For complex user requests, the Planner decomposes them into a sequence
// of steps BEFORE execution. Each step maps to a tool call or a sub-task.
//
// Design for small models (2-4B params):
// - Simple linear plans (no tree/graph — too complex for small models)
// - Max 5 steps per plan
// - Each step is a (thought, action, tool) tuple
// - Plan revision: if a step fails, the planner can skip or retry
//
// When to plan vs direct answer:
// - Simple questions ("what time is it?") → direct, no planning
// - Complex requests ("summarize yesterday's meeting and create reminders for all action items")
//   → plan: [search meeting] → [get action items] → [create reminders]

// MARK: - Plan

public struct Plan: Codable, Sendable {
    public let id: UUID
    public let goal: String
    public var steps: [PlanStep]
    public var status: PlanStatus
    public let createdAt: Date

    public enum PlanStatus: String, Codable, Sendable {
        case pending
        case executing
        case completed
        case partiallyCompleted
        case failed
    }

    public init(goal: String, steps: [PlanStep]) {
        self.id = UUID()
        self.goal = goal
        self.steps = steps
        self.status = .pending
        self.createdAt = Date()
    }

    /// Progress fraction (0.0 to 1.0)
    public var progress: Double {
        guard !steps.isEmpty else { return 0 }
        let completed = steps.filter { $0.status == .completed || $0.status == .skipped }.count
        return Double(completed) / Double(steps.count)
    }
}

// MARK: - Plan Step

public struct PlanStep: Codable, Identifiable, Sendable {
    public let id: UUID
    public let index: Int
    public let thought: String       // reasoning for this step
    public let action: String        // what to do
    public let toolName: String?     // tool to invoke (nil = LLM reasoning only)
    public let toolParameters: String? // JSON parameters for tool
    public var status: StepStatus
    public var result: String?
    public var error: String?

    public enum StepStatus: String, Codable, Sendable {
        case pending
        case executing
        case completed
        case failed
        case skipped
    }

    public init(index: Int, thought: String, action: String, toolName: String? = nil, toolParameters: String? = nil) {
        self.id = UUID()
        self.index = index
        self.thought = thought
        self.action = action
        self.toolName = toolName
        self.toolParameters = toolParameters
        self.status = .pending
    }
}

// MARK: - Planner

public actor Planner {

    private let llm: any LLMBackend
    private let maxSteps: Int

    public init(llm: any LLMBackend, maxSteps: Int = 5) {
        self.llm = llm
        self.maxSteps = maxSteps
    }

    // MARK: - Should Plan?

    /// Determine if a request needs planning (multi-step) or can be answered directly.
    /// Uses heuristics — no LLM call needed.
    public nonisolated func needsPlanning(_ message: String, availableTools: [any AgentTool]) -> Bool {
        let lower = message.lowercased()

        // Multi-action indicators
        let multiActionKeywords = [
            " và ", " and ", " then ", " sau đó ", " rồi ", " tiếp ",
            " all ", " tất cả ", " mỗi ", " each ", " every ",
            "create reminders for", "tạo nhắc nhở cho",
            "summarize and", "tóm tắt và"
        ]

        for keyword in multiActionKeywords {
            if lower.contains(keyword) { return true }
        }

        // Multiple question marks
        if message.filter({ $0 == "?" }).count >= 2 { return true }

        // Long request (likely complex)
        if message.count > 200 { return true }

        return false
    }

    // MARK: - Generate Plan

    /// Ask the LLM to decompose a complex request into steps.
    public func generatePlan(
        goal: String,
        availableTools: [any AgentTool],
        context: String = ""
    ) async -> Plan {
        let toolList = availableTools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        let prompt = """
        Decompose this request into a step-by-step plan (max \(maxSteps) steps).
        Each step should have: thought (why), action (what to do), and optionally a tool to use.

        Available tools:
        \(toolList)

        \(context.isEmpty ? "" : "Context:\n\(context)\n")

        Request: \(goal)

        Respond ONLY with JSON array:
        [{"thought": "why this step", "action": "what to do", "tool": "tool_name or null", "parameters": "JSON string or null"}]
        """

        let response = await llm.generate(prompt: prompt, maxTokens: 512, temperature: 0.3)
        return parsePlan(goal: goal, response: response)
    }

    // MARK: - Execute Plan

    /// Execute a plan step by step, using the provided tool executor.
    /// Returns the updated plan with results.
    public func executePlan(
        _ plan: Plan,
        toolExecutor: @Sendable (String, String) async -> ToolResult,
        onStepComplete: (@Sendable (PlanStep) -> Void)? = nil
    ) async -> Plan {
        var plan = plan
        plan.status = .executing

        for i in 0..<plan.steps.count {
            plan.steps[i].status = .executing

            if let toolName = plan.steps[i].toolName {
                let params = plan.steps[i].toolParameters ?? "{}"
                let result = await toolExecutor(toolName, params)

                if result.isError {
                    plan.steps[i].status = .failed
                    plan.steps[i].error = result.content

                    // CoPaw stability: skip failed step, continue with next
                    // (don't abort entire plan for one failure)
                    continue
                }

                plan.steps[i].status = .completed
                plan.steps[i].result = result.content
            } else {
                // Reasoning-only step — mark as completed
                plan.steps[i].status = .completed
                plan.steps[i].result = "Reasoning step completed"
            }

            onStepComplete?(plan.steps[i])
        }

        // Determine final status
        let completedCount = plan.steps.filter { $0.status == .completed }.count
        let totalCount = plan.steps.count

        if completedCount == totalCount {
            plan.status = .completed
        } else if completedCount > 0 {
            plan.status = .partiallyCompleted
        } else {
            plan.status = .failed
        }

        return plan
    }

    // MARK: - Summarize Plan Results

    /// Ask the LLM to synthesize plan results into a final answer.
    public func summarizePlanResults(_ plan: Plan) async -> String {
        let stepsDescription = plan.steps.map { step -> String in
            let status = step.status == .completed ? "done" : "failed"
            let result = step.result ?? step.error ?? "no result"
            return "Step \(step.index + 1) [\(status)]: \(step.action) → \(result)"
        }.joined(separator: "\n")

        let prompt = """
        A multi-step task was executed. Synthesize the results into a clear, concise answer for the user.

        Goal: \(plan.goal)

        Steps and results:
        \(stepsDescription)

        Provide a natural language summary of what was accomplished.
        """

        return await llm.generate(prompt: prompt, maxTokens: 512, temperature: 0.5)
    }

    // MARK: - Parse Plan from LLM response

    private func parsePlan(goal: String, response: String) -> Plan {
        // Extract JSON array from response
        guard let startIdx = response.firstIndex(of: "["),
              let endIdx = response.lastIndex(of: "]") else {
            // Fallback: single-step plan
            return Plan(goal: goal, steps: [
                PlanStep(index: 0, thought: "Direct execution", action: goal)
            ])
        }

        let jsonStr = String(response[startIdx...endIdx])
        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return Plan(goal: goal, steps: [
                PlanStep(index: 0, thought: "Direct execution", action: goal)
            ])
        }

        let steps = array.prefix(maxSteps).enumerated().map { idx, item -> PlanStep in
            PlanStep(
                index: idx,
                thought: item["thought"] as? String ?? "",
                action: item["action"] as? String ?? "",
                toolName: item["tool"] as? String,
                toolParameters: item["parameters"] as? String
            )
        }

        return Plan(goal: goal, steps: steps.isEmpty ? [PlanStep(index: 0, thought: "Direct execution", action: goal)] : steps)
    }
}
