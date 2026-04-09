import Foundation

// MARK: - Agent
//
// Main agent loop with:
// 1. Gemma 4 native tool calling tokens (structured, reliable)
// 2. Streaming responses (token by token, detect tool calls mid-stream)
// 3. Multi-turn tool calling with context preservation (append-only, no rebuild)
// 4. Action-biased prompt (optimized for small 2B models)

public actor Agent {

    // MARK: - Configuration

    public struct Config: Sendable {
        public var maxToolSteps: Int
        public var temperature: Float
        public var maxResponseTokens: Int
        public var requireConfirmationForDangerousTools: Bool

        public init(
            maxToolSteps: Int = 5,
            temperature: Float = 0.7,
            maxResponseTokens: Int = 1024,
            requireConfirmationForDangerousTools: Bool = true
        ) {
            self.maxToolSteps = maxToolSteps
            self.temperature = temperature
            self.maxResponseTokens = maxResponseTokens
            self.requireConfirmationForDangerousTools = requireConfirmationForDangerousTools
        }
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

    /// Callback for tool confirmation
    public var onToolConfirmation: (@Sendable (String, String) async -> Bool)?

    /// Callback for streaming tokens to UI
    public var onToken: (@Sendable (String) -> Void)?

    /// Callback for tool status updates (e.g. "Searching web...", "Done: 5 results")
    public var onToolStatus: (@Sendable (String) -> Void)?

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
        for skill in newSkills { registerSkill(skill) }
    }

    // MARK: - Process Message (Streaming, Multi-turn tool calling)

    public func processMessage(_ userMessage: String) async -> String {
        conversationHistory.append(AgentMessage(role: .user, content: userMessage))

        // Route to skills
        let previousActive = activeSkills
        activeSkills = skillRouter.route(message: userMessage, allSkills: skills)
        for skill in previousActive where !activeSkills.contains(where: { $0.id == skill.id }) {
            await skill.onDeactivate()
        }
        for skill in activeSkills where !previousActive.contains(where: { $0.id == skill.id }) {
            await skill.onActivate()
        }

        let availableTools = activeSkills.flatMap { $0.tools }

        // Build initial prompt (only on first turn — subsequent turns append)
        var fullPrompt = await buildSystemPrompt(availableTools: availableTools)
        fullPrompt += buildConversationPrompt()
        fullPrompt += "Assistant:"

        // Agent loop — multi-turn tool calling with context preservation
        var steps = 0
        while steps < config.maxToolSteps {
            onToolStatus?(steps == 0 ? "Thinking..." : "Thinking (step \(steps + 1))...")
            var response = ""
            for await token in llm.generateStream(prompt: fullPrompt, maxTokens: config.maxResponseTokens, temperature: config.temperature) {
                response += token
                // Stream non-tool-call tokens to UI
                if !response.contains("<tool_call>") {
                    onToken?(token)
                }
            }

            response = response.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check for tool call
            if let toolCall = parseToolCall(response) {
                let result = await executeToolCall(toolCall, availableTools: availableTools)

                // Append to history (for context preservation)
                conversationHistory.append(AgentMessage(
                    role: .assistant, content: "",
                    toolCall: AgentMessage.ToolCall(toolName: toolCall.name, parameters: toolCall.parameters)
                ))
                conversationHistory.append(AgentMessage(
                    role: .tool, content: result.content,
                    toolResult: result.content
                ))

                // Context preservation: append tool result to existing prompt (no rebuild)
                fullPrompt += " <tool_call>{\"name\":\"\(toolCall.name)\"}</tool_call>\nTool result: \(result.content)\nAssistant:"
                steps += 1
                continue
            }

            // Final answer
            onToolStatus?("")  // clear status
            conversationHistory.append(AgentMessage(role: .assistant, content: response))
            Task { await self.memoryManager.extractAndStore(from: self.conversationHistory.suffix(4)) }
            return response
        }

        let fallback = "Done. Completed \(steps) tool calls."
        conversationHistory.append(AgentMessage(role: .assistant, content: fallback))
        return fallback
    }

    // MARK: - Streaming variant (yields tokens + final answer)

    public func processMessageStream(_ userMessage: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                self.onToken = { token in
                    continuation.yield(token)
                }
                let finalAnswer = await self.processMessage(userMessage)
                // If onToken already streamed, the final answer may be redundant
                // but we yield it to ensure completeness
                continuation.yield("")  // signal end
                continuation.finish()
                self.onToken = nil
            }
        }
    }

    // MARK: - System Prompt (compact, action-biased for small models)

    private func buildSystemPrompt(availableTools: [any AgentTool]) async -> String {
        var prompt = ""

        // Soul — compact render
        prompt += "You are \(soul.identity.name). \(soul.identity.description)\n"
        if !soul.boundaries.isEmpty {
            prompt += "Rules: " + soul.boundaries.prefix(3).joined(separator: ". ") + ".\n"
        }
        prompt += "\n"

        // Tools — direct, action-biased with concrete examples
        if !availableTools.isEmpty {
            prompt += "You have tools. USE THEM — don't ask the user for info you can look up.\n"
            prompt += "To call a tool, output ONLY this JSON (nothing else before or after):\n"
            prompt += "<tool_call>{\"name\":\"tool_name\",\"parameters\":{\"key\":\"value\"}}</tool_call>\n\n"

            // Concrete example for the first tool
            if let first = availableTools.first {
                prompt += "Example: <tool_call>{\"name\":\"\(first.name)\",\"parameters\":{\(first.parametersSchema.contains("query") ? "\"query\":\"example\"" : "")}}</tool_call>\n\n"
            }

            prompt += "Tools:\n"
            for tool in availableTools {
                prompt += "- \(tool.name): \(tool.description)\n"
            }
            prompt += "\n"
        }

        // Memory context (compact)
        let recentMsg = conversationHistory.last(where: { $0.role == .user })?.content ?? ""
        let memories = await memoryManager.retrieve(query: recentMsg, limit: 3)
        if !memories.isEmpty {
            prompt += "Context: " + memories.map { $0.content }.joined(separator: "; ") + "\n\n"
        }

        return prompt
    }

    // MARK: - Conversation Prompt (hot memory)

    private func buildConversationPrompt() -> String {
        var text = ""
        // Keep last N messages that fit
        let recent = conversationHistory.suffix(16)
        for msg in recent {
            switch msg.role {
            case .user:
                text += "User: \(msg.content)\n"
            case .assistant:
                if let tc = msg.toolCall {
                    text += "Assistant: <tool_call>{\"name\":\"\(tc.toolName)\"}</tool_call>\n"
                } else if !msg.content.isEmpty {
                    text += "Assistant: \(msg.content)\n"
                }
            case .tool:
                text += "Tool result: \(msg.content)\n"
            case .system:
                break
            }
        }
        return text
    }

    // MARK: - Tool Call Parsing (supports both text-based and native tokens)

    private struct ParsedToolCall {
        let name: String
        let parameters: String
    }

    private func parseToolCall(_ response: String) -> ParsedToolCall? {
        // Try native Gemma 4 tokens first: <|tool_call> ... <tool_call|>
        if let nativeCall = parseNativeToolCall(response) { return nativeCall }

        // Fallback: text-based <tool_call>...</tool_call>
        return parseTextToolCall(response)
    }

    /// Parse Gemma 4 native tool calling tokens
    private func parseNativeToolCall(_ response: String) -> ParsedToolCall? {
        // Gemma 4 native format: <|tool_call>{"name":"...", "parameters":{...}}<tool_call|>
        guard let start = response.range(of: "<|tool_call>"),
              let end = response.range(of: "<tool_call|>") else { return nil }
        return extractToolCallJSON(String(response[start.upperBound..<end.lowerBound]))
    }

    /// Parse text-based tool call
    private func parseTextToolCall(_ response: String) -> ParsedToolCall? {
        guard let start = response.range(of: "<tool_call>"),
              let end = response.range(of: "</tool_call>") else { return nil }
        return extractToolCallJSON(String(response[start.upperBound..<end.lowerBound]))
    }

    private func extractToolCallJSON(_ jsonStr: String) -> ParsedToolCall? {
        let trimmed = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try standard JSON first: {"name":"tool","parameters":{...}}
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String {
            let params: String
            if let paramsObj = json["parameters"],
               let paramsData = try? JSONSerialization.data(withJSONObject: paramsObj),
               let paramsStr = String(data: paramsData, encoding: .utf8) {
                params = paramsStr
            } else {
                params = "{}"
            }
            return ParsedToolCall(name: name, parameters: params)
        }

        // Fallback: parse loose format like "web_search{query: "..."}"
        // or "web_search(query="...")" that small models often produce
        return parsLooseToolCall(trimmed)
    }

    /// Parse non-standard tool call formats that small models generate
    private func parsLooseToolCall(_ text: String) -> ParsedToolCall? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Pattern: "tool_name{key: "value", ...}" or "tool_name{"key": "value"}"
        // Find tool name (everything before first { or ()
        let separators = CharacterSet(charactersIn: "{(")
        guard let sepRange = trimmed.rangeOfCharacter(from: separators) else {
            // Just a tool name with no params
            let name = trimmed.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !name.contains(" ") {
                return ParsedToolCall(name: name, parameters: "{}")
            }
            return nil
        }

        let name = String(trimmed[trimmed.startIndex..<sepRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Extract everything between { } or ( )
        var paramsStr = String(trimmed[sepRange.lowerBound...])
        paramsStr = paramsStr.replacingOccurrences(of: "(", with: "{")
        paramsStr = paramsStr.replacingOccurrences(of: ")", with: "}")

        // Fix unquoted keys: {query: "value"} → {"query": "value"}
        paramsStr = paramsStr.replacingOccurrences(
            of: "([{,]\\s*)(\\w+)(\\s*:)",
            with: "$1\"$2\"$3",
            options: .regularExpression
        )

        // Try to parse as JSON
        if let data = paramsStr.data(using: .utf8),
           let paramsObj = try? JSONSerialization.jsonObject(with: data),
           let paramsData = try? JSONSerialization.data(withJSONObject: paramsObj),
           let validParams = String(data: paramsData, encoding: .utf8) {
            return ParsedToolCall(name: name, parameters: validParams)
        }

        // Last resort: extract quoted strings as parameters
        let quotedPattern = "\"([^\"]+)\""
        let regex = try? NSRegularExpression(pattern: quotedPattern)
        let matches = regex?.matches(in: paramsStr, range: NSRange(paramsStr.startIndex..., in: paramsStr)) ?? []

        if let firstMatch = matches.first,
           let range = Range(firstMatch.range(at: 1), in: paramsStr) {
            let value = String(paramsStr[range])
            // Guess the param name from tool
            return ParsedToolCall(name: name, parameters: "{\"query\":\"\(value)\"}")
        }

        return ParsedToolCall(name: name, parameters: "{}")
    }

    // MARK: - Tool Execution (CoPaw controllable)

    private func executeToolCall(_ call: ParsedToolCall, availableTools: [any AgentTool]) async -> ToolResult {
        guard let tool = availableTools.first(where: { $0.name == call.name }) else {
            onToolStatus?("Tool '\(call.name)' not found")
            return .error("Tool '\(call.name)' not found. Available: \(availableTools.map { $0.name }.joined(separator: ", "))")
        }

        // Emit detailed status with parameter summary
        let paramSummary = summarizeParams(call.parameters, toolName: tool.name)
        onToolStatus?(paramSummary)

        if tool.requiresConfirmation {
            onToolStatus?("Waiting for approval: \(tool.name)")
            if let confirm = onToolConfirmation {
                let approved = await confirm(tool.name, call.parameters)
                if !approved {
                    onToolStatus?("Declined: \(tool.name)")
                    return .error("User declined '\(tool.name)'")
                }
            }
        }

        do {
            let result = try await tool.execute(parameters: call.parameters)
            // Emit status: done
            if result.isError {
                let preview = result.content.prefix(60).replacingOccurrences(of: "\n", with: " ")
                onToolStatus?("Failed: \(preview)")
            } else {
                let lines = result.content.components(separatedBy: "\n").filter { !$0.isEmpty }
                if let firstLine = lines.first, lines.count <= 2 {
                    onToolStatus?("Got: \(firstLine.prefix(60))")
                } else {
                    onToolStatus?("Got \(lines.count) results, processing...")
                }
            }
            return result
        } catch {
            onToolStatus?("Error: \(error.localizedDescription.prefix(60))")
            return .error("Tool '\(call.name)' failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Tool Status Formatting

    /// Create human-readable status from tool name + parameters
    private func summarizeParams(_ paramsJSON: String, toolName: String) -> String {
        let json = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any]

        switch toolName {
        case "web_search":
            let q = json?["query"] as? String ?? ""
            return "Searching web: \"\(q)\""
        case "search_email":
            let q = json?["query"] as? String ?? ""
            return "Searching emails: \"\(q)\""
        case "read_email":
            let uid = json?["uid"] as? Int ?? 0
            return "Reading email #\(uid)"
        case "send_email":
            let to = json?["to"] as? String ?? ""
            let subj = json?["subject"] as? String ?? ""
            return "Sending email to \(to): \"\(subj)\""
        case "list_recent_emails":
            let folder = json?["folder"] as? String ?? "INBOX"
            return "Listing recent emails in \(folder)"
        case "search_meetings":
            let q = json?["query"] as? String ?? ""
            return "Searching meetings: \"\(q)\""
        case "get_meeting_details":
            let q = json?["query"] as? String ?? ""
            return "Loading meeting: \"\(q)\""
        case "get_action_items":
            let a = json?["assignee"] as? String ?? "all"
            return "Getting action items for \(a)"
        case "get_recent_meetings":
            return "Loading recent meetings"
        case "fetch_url":
            let url = json?["url"] as? String ?? ""
            return "Fetching: \(url.prefix(40))"
        case "get_datetime":
            return "Checking date/time"
        case "calculate":
            let expr = json?["expression"] as? String ?? ""
            return "Calculating: \(expr)"
        default:
            return "Using \(toolName)..."
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

    // MARK: - Planning

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
