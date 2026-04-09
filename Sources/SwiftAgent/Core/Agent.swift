import Foundation

// MARK: - Agent
//
// The main agent loop. Orchestrates LLM, skills, tools, and memory.
//
// Flow:
// 1. User message → skill router selects active skills
// 2. Build prompt: system + memory context + active skill tools
// 3. LLM generates → parse for tool calls or final answer
// 4. If tool call → confirm if needed → execute → append result → loop (max N steps)
// 5. If final answer → return to user
// 6. Async: extract memories from conversation

public actor Agent {

    // MARK: - Configuration

    public struct Config: Sendable {
        public var systemPrompt: String
        public var maxToolSteps: Int
        public var temperature: Float
        public var maxResponseTokens: Int
        public var requireConfirmationForDangerousTools: Bool

        public init(
            systemPrompt: String = Self.defaultSystemPrompt,
            maxToolSteps: Int = 5,
            temperature: Float = 0.7,
            maxResponseTokens: Int = 1024,
            requireConfirmationForDangerousTools: Bool = true
        ) {
            self.systemPrompt = systemPrompt
            self.maxToolSteps = maxToolSteps
            self.temperature = temperature
            self.maxResponseTokens = maxResponseTokens
            self.requireConfirmationForDangerousTools = requireConfirmationForDangerousTools
        }

        public static let defaultSystemPrompt = """
        You are a personal AI agent running locally on the user's device. All data stays private.

        TOOL CALLING:
        - You have access to tools. To use one, respond ONLY with:
          <tool_call>{"name": "tool_name", "parameters": {...}}</tool_call>
        - Do NOT narrate routine tool calls — just call the tool directly.
        - Narrate only when: multi-step work, complex reasoning, or sensitive actions.
        - After receiving tool results, synthesize a clear answer for the user.
        - If a tool fails, explain what happened and suggest alternatives.
        - For sensitive actions (send email, create events, delete), ALWAYS confirm with user first.

        RESPONSE STYLE:
        - Respond in the SAME LANGUAGE as the user's message.
        - Be concise. Lead with the answer, not the reasoning.
        - Use markdown for structured content (lists, code, tables).
        - If unsure, say so — never fabricate information.
        - When citing data from tools, mention the source.

        MEMORY:
        - You remember context from this conversation and past interactions.
        - When asked about previous topics, search memory before answering.
        - Learn user preferences over time (name, work context, habits).

        MULTI-STEP TASKS:
        - For complex requests involving multiple actions, break them into steps.
        - Execute steps sequentially, reporting progress.
        - If one step fails, continue with remaining steps when possible.
        """
    }

    // MARK: - State

    private let llm: any LLMBackend
    private let config: Config
    private var soul: Soul
    private var skills: [any AgentSkill] = []
    private var activeSkills: [any AgentSkill] = []
    private var conversationHistory: [AgentMessage] = []
    private let memoryManager: MemoryManager
    private let planner: Planner
    private let skillRouter: SkillRouter

    /// Callback for tool confirmation (CoPaw-style controllable execution)
    public var onToolConfirmation: (@Sendable (String, String) async -> Bool)?

    /// Callback for streaming tokens to UI
    public var onToken: (@Sendable (String) -> Void)?

    // MARK: - Init

    public init(
        llm: any LLMBackend,
        config: Config = Config(),
        soul: Soul = .default,
        memoryStore: (any MemoryStore)? = nil
    ) {
        self.llm = llm
        self.config = config
        self.soul = soul
        self.memoryManager = MemoryManager(store: memoryStore ?? InMemoryStore())
        self.planner = Planner(llm: llm, maxSteps: config.maxToolSteps)
        self.skillRouter = SkillRouter()
    }

    // MARK: - Skill Registration

    public func registerSkill(_ skill: any AgentSkill) {
        skills.append(skill)
        skillRouter.register(skill)
    }

    public func registerSkills(_ newSkills: [any AgentSkill]) {
        for skill in newSkills {
            registerSkill(skill)
        }
    }

    // MARK: - Process Message (Main Entry Point)

    /// Process a user message and return the agent's response.
    /// This is the main agent loop.
    public func processMessage(_ userMessage: String) async -> String {
        // 1. Add user message to history
        conversationHistory.append(AgentMessage(role: .user, content: userMessage))

        // 2. Route to relevant skills
        let previousActive = activeSkills
        activeSkills = skillRouter.route(message: userMessage, allSkills: skills)

        // Lifecycle: deactivate old, activate new
        for skill in previousActive where !activeSkills.contains(where: { $0.id == skill.id }) {
            await skill.onDeactivate()
        }
        for skill in activeSkills where !previousActive.contains(where: { $0.id == skill.id }) {
            await skill.onActivate()
        }

        // 3. Gather available tools from active skills
        let availableTools = activeSkills.flatMap { $0.tools }

        // 4. Build prompt
        let prompt = await buildPrompt(availableTools: availableTools)

        // 5. Agent loop (tool calling with fallback)
        var steps = 0
        var currentPrompt = prompt

        while steps < config.maxToolSteps {
            let response = await llm.generate(
                prompt: currentPrompt,
                maxTokens: config.maxResponseTokens,
                temperature: config.temperature
            )

            // Parse for tool calls
            if let toolCall = parseToolCall(response) {
                // Execute tool
                let result = await executeToolCall(toolCall, availableTools: availableTools)

                // Append tool interaction to history
                conversationHistory.append(AgentMessage(
                    role: .assistant, content: response,
                    toolCall: AgentMessage.ToolCall(toolName: toolCall.name, parameters: toolCall.parameters)
                ))
                conversationHistory.append(AgentMessage(
                    role: .tool, content: result.content,
                    toolResult: result.content
                ))

                // Rebuild prompt with tool result for next iteration
                currentPrompt = await buildPrompt(availableTools: availableTools)
                steps += 1
                continue
            }

            // No tool call — this is the final answer
            let finalAnswer = response.trimmingCharacters(in: .whitespacesAndNewlines)
            conversationHistory.append(AgentMessage(role: .assistant, content: finalAnswer))

            // 6. Async memory extraction
            Task { await self.memoryManager.extractAndStore(from: self.conversationHistory.suffix(4)) }

            return finalAnswer
        }

        // Max steps exceeded — return what we have
        let fallback = "I've reached the maximum number of tool calls. Here's what I found so far based on the conversation."
        conversationHistory.append(AgentMessage(role: .assistant, content: fallback))
        return fallback
    }

    // MARK: - Streaming variant

    public func processMessageStream(_ userMessage: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let response = await self.processMessage(userMessage)
                continuation.yield(response)
                continuation.finish()
            }
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt(availableTools: [any AgentTool]) async -> String {
        var prompt = ""

        // 1. Soul (identity, personality, boundaries)
        prompt += soul.renderSystemPrompt()

        // 2. Config system prompt (tool calling instructions)
        prompt += config.systemPrompt + "\n\n"

        // 3. Skill context
        for skill in activeSkills where !skill.systemPromptExtension.isEmpty {
            prompt += skill.systemPromptExtension + "\n\n"
        }

        // 4. Memory context (warm tier + user profile)
        let recentUserMsg = conversationHistory.last(where: { $0.role == .user })?.content ?? ""
        let memoryContext = await memoryManager.buildContext(for: recentUserMsg, limit: 5)
        if !memoryContext.isEmpty {
            prompt += memoryContext + "\n"
        }

        // 5. Available tools
        if !availableTools.isEmpty {
            prompt += "AVAILABLE TOOLS:\n"
            for tool in availableTools {
                prompt += "- \(tool.name): \(tool.description)\n  Parameters: \(tool.parametersSchema)\n"
            }
            prompt += "\nTo use a tool: <tool_call>{\"name\": \"tool_name\", \"parameters\": {...}}</tool_call>\n\n"
        }

        // 6. Conversation history (hot memory — trimmed to fit context)
        prompt += "CONVERSATION:\n"
        let maxHistoryTokens = llm.contextSize / 3  // reserve 1/3 of context for history
        var historyText = ""
        for msg in conversationHistory.reversed() {
            let line: String
            switch msg.role {
            case .user:      line = "User: \(msg.content)\n"
            case .assistant: line = "Assistant: \(msg.content)\n"
            case .tool:      line = "Tool result: \(msg.content)\n"
            case .system:    continue
            }
            let newText = line + historyText
            if llm.countTokens(newText) > maxHistoryTokens { break }
            historyText = newText
        }
        prompt += historyText
        prompt += "Assistant: "

        return prompt
    }

    // MARK: - Tool Call Parsing

    private struct ParsedToolCall {
        let name: String
        let parameters: String
    }

    private func parseToolCall(_ response: String) -> ParsedToolCall? {
        // Parse <tool_call>{"name": "...", "parameters": {...}}</tool_call>
        guard let start = response.range(of: "<tool_call>"),
              let end = response.range(of: "</tool_call>") else { return nil }

        let jsonStr = String(response[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }

        let params: String
        if let paramsObj = json["parameters"] {
            if let paramsData = try? JSONSerialization.data(withJSONObject: paramsObj),
               let paramsStr = String(data: paramsData, encoding: .utf8) {
                params = paramsStr
            } else {
                params = "{}"
            }
        } else {
            params = "{}"
        }

        return ParsedToolCall(name: name, parameters: params)
    }

    // MARK: - Tool Execution (CoPaw-style controllable)

    private func executeToolCall(_ call: ParsedToolCall, availableTools: [any AgentTool]) async -> ToolResult {
        guard let tool = availableTools.first(where: { $0.name == call.name }) else {
            return .error("Tool '\(call.name)' not found")
        }

        // Confirmation gate (CoPaw controllable pattern)
        if tool.requiresConfirmation || config.requireConfirmationForDangerousTools {
            if let confirm = onToolConfirmation {
                let approved = await confirm(tool.name, call.parameters)
                if !approved {
                    return .error("User declined to execute '\(tool.name)'")
                }
            }
        }

        // Execute with fallback (CoPaw stability pattern)
        do {
            return try await tool.execute(parameters: call.parameters)
        } catch {
            return .error("Tool '\(call.name)' failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Soul Management

    public func getSoul() -> Soul { soul }
    public func setSoul(_ newSoul: Soul) { soul = newSoul }

    // MARK: - Memory Management

    public func addMemory(_ content: String, type: MemoryEntry.MemoryType) async {
        await memoryManager.addMemory(content, type: type)
    }

    public func searchMemory(query: String, limit: Int = 5) async -> [MemoryEntry] {
        await memoryManager.retrieve(query: query, limit: limit)
    }

    public func applyMemoryDecay() async {
        await memoryManager.applyDecay()
    }

    public func getMemoryCount() async -> Int {
        await memoryManager.memoryCount()
    }

    // MARK: - Planning (public API)

    /// Check if a message needs multi-step planning
    public func needsPlanning(_ message: String) -> Bool {
        let tools = activeSkills.flatMap { $0.tools } + skills.flatMap { $0.tools }
        return planner.needsPlanning(message, availableTools: tools)
    }

    // MARK: - Session Management

    public func clearHistory() {
        conversationHistory = []
    }

    public func getHistory() -> [AgentMessage] {
        conversationHistory
    }

    public func setHistory(_ history: [AgentMessage]) {
        conversationHistory = history
    }
}
