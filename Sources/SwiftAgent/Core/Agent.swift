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
        You are a helpful personal AI assistant running on-device. You have access to tools and skills.

        RULES:
        - Use tools when you need external information or to perform actions
        - To call a tool, respond with: <tool_call>{"name": "tool_name", "parameters": {...}}</tool_call>
        - After receiving tool results, synthesize a final answer for the user
        - Be concise and accurate
        - If you cannot answer, say so honestly
        - Respond in the same language as the user
        """
    }

    // MARK: - State

    private let llm: any LLMBackend
    private let config: Config
    private var skills: [any AgentSkill] = []
    private var activeSkills: [any AgentSkill] = []
    private var conversationHistory: [AgentMessage] = []
    private let memoryManager: MemoryManager
    private let skillRouter: SkillRouter

    /// Callback for tool confirmation (CoPaw-style controllable execution)
    public var onToolConfirmation: (@Sendable (String, String) async -> Bool)?

    /// Callback for streaming tokens to UI
    public var onToken: (@Sendable (String) -> Void)?

    // MARK: - Init

    public init(llm: any LLMBackend, config: Config = Config(), memoryStore: (any MemoryStore)? = nil) {
        self.llm = llm
        self.config = config
        self.memoryManager = MemoryManager(store: memoryStore ?? InMemoryStore())
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
        var prompt = config.systemPrompt + "\n\n"

        // Skill context
        for skill in activeSkills where !skill.systemPromptExtension.isEmpty {
            prompt += skill.systemPromptExtension + "\n\n"
        }

        // Memory context (warm tier)
        let recentUserMsg = conversationHistory.last(where: { $0.role == .user })?.content ?? ""
        let memories = await memoryManager.retrieveRelevant(for: recentUserMsg, limit: 5)
        if !memories.isEmpty {
            prompt += "RELEVANT CONTEXT:\n"
            for mem in memories {
                prompt += "- \(mem.content)\n"
            }
            prompt += "\n"
        }

        // Available tools
        if !availableTools.isEmpty {
            prompt += "AVAILABLE TOOLS:\n"
            for tool in availableTools {
                prompt += "- \(tool.name): \(tool.description)\n  Parameters: \(tool.parametersSchema)\n"
            }
            prompt += "\nTo use a tool: <tool_call>{\"name\": \"tool_name\", \"parameters\": {...}}</tool_call>\n\n"
        }

        // Conversation history (hot memory)
        prompt += "CONVERSATION:\n"
        let recentHistory = conversationHistory.suffix(20) // keep last 20 messages
        for msg in recentHistory {
            switch msg.role {
            case .user:    prompt += "User: \(msg.content)\n"
            case .assistant: prompt += "Assistant: \(msg.content)\n"
            case .tool:    prompt += "Tool result: \(msg.content)\n"
            case .system:  break
            }
        }
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
