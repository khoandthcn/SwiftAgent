import Foundation

// MARK: - Core Protocols
//
// SwiftAgent architecture (inspired by CoPaw):
//
//   User ──► Agent Loop ──► LLM (Gemma 4 / Apple FM)
//                │                    │
//                │◄── tool_call ──────┘
//                │
//                ▼
//           Skill Router ──► Skill A (has tools + prompt)
//                │           Skill B
//                │           Skill C
//                ▼
//           Tool Executor ──► Tool 1 (execute + return)
//                │            Tool 2
//                ▼
//           Memory Manager ──► Hot (context window)
//                              Warm (extracted facts)
//                              Cold (raw history)

// MARK: - LLM Backend

/// Abstract LLM inference backend. Implementations: GemmaBackend, AppleFMBackend
public protocol LLMBackend: Sendable {
    /// Generate a complete response (blocking)
    func generate(prompt: String, maxTokens: Int, temperature: Float) async -> String

    /// Generate streaming tokens
    func generateStream(prompt: String, maxTokens: Int, temperature: Float) -> AsyncStream<String>

    /// Count tokens in text
    func countTokens(_ text: String) -> Int

    /// Whether the backend is ready
    var isReady: Bool { get }

    /// Available context window size
    var contextSize: Int { get }
}

// MARK: - Tool

/// A tool the agent can invoke. Tools are stateless functions.
public protocol AgentTool: Identifiable, Sendable {
    /// Unique tool identifier
    var id: String { get }

    /// Human-readable name
    var name: String { get }

    /// Description for the LLM (what this tool does, when to use it)
    var description: String { get }

    /// JSON schema of parameters
    var parametersSchema: String { get }

    /// Execute the tool with given parameters (JSON string)
    func execute(parameters: String) async throws -> ToolResult

    /// Whether this tool requires user confirmation before execution
    var requiresConfirmation: Bool { get }
}

public extension AgentTool {
    var requiresConfirmation: Bool { false }
}

/// Result of a tool execution
public struct ToolResult: Sendable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func success(_ content: String) -> ToolResult {
        ToolResult(content: content)
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true)
    }
}

// MARK: - Skill

/// A skill is a domain-specific capability with its own tools, prompt context, and behavior.
/// Skills are the primary unit of agent extensibility.
///
/// Example skills: MeetingSkill, CalendarSkill, ReminderSkill, WebSearchSkill
public protocol AgentSkill: Identifiable, Sendable {
    /// Unique skill identifier
    var id: String { get }

    /// Human-readable name
    var name: String { get }

    /// Description for routing (when should this skill be activated)
    var description: String { get }

    /// Tools provided by this skill
    var tools: [any AgentTool] { get }

    /// Additional system prompt context when this skill is active
    var systemPromptExtension: String { get }

    /// Keywords/intents that trigger this skill (for router)
    var triggerKeywords: [String] { get }

    /// Priority (higher = preferred when multiple skills match)
    var priority: Int { get }

    /// Called when skill is activated for a conversation turn
    func onActivate() async

    /// Called when skill is deactivated
    func onDeactivate() async
}

public extension AgentSkill {
    var priority: Int { 0 }
    var systemPromptExtension: String { "" }
    func onActivate() async {}
    func onDeactivate() async {}
}

// MARK: - Memory

/// Memory entry stored in warm/cold tiers
public struct MemoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let content: String
    public let type: MemoryType
    public let createdAt: Date
    public var relevanceScore: Float
    public var accessCount: Int

    public enum MemoryType: String, Codable, Sendable {
        case fact           // extracted fact ("User prefers Vietnamese")
        case entity         // named entity ("Hung is the project lead")
        case preference     // user preference
        case conversation   // conversation summary
        case actionItem     // pending action item
    }

    public init(content: String, type: MemoryType, relevanceScore: Float = 1.0) {
        self.id = UUID()
        self.content = content
        self.type = type
        self.createdAt = Date()
        self.relevanceScore = relevanceScore
        self.accessCount = 0
    }
}

/// Memory storage backend
public protocol MemoryStore: Sendable {
    /// Store a memory entry
    func store(_ entry: MemoryEntry) async

    /// Retrieve relevant memories for a query
    func retrieve(query: String, limit: Int) async -> [MemoryEntry]

    /// Get all memories of a specific type
    func getByType(_ type: MemoryEntry.MemoryType, limit: Int) async -> [MemoryEntry]

    /// Remove a memory entry
    func remove(id: UUID) async

    /// Total memory count
    func count() async -> Int

    /// Compress/forget old memories when storage exceeds limit
    func compact(maxEntries: Int) async
}

// MARK: - Conversation

/// A message in the conversation history
public struct AgentMessage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let role: Role
    public let content: String
    public let timestamp: Date
    public var toolCall: ToolCall?
    public var toolResult: String?

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
        case tool
    }

    public struct ToolCall: Codable, Sendable {
        public let toolName: String
        public let parameters: String

        public init(toolName: String, parameters: String) {
            self.toolName = toolName
            self.parameters = parameters
        }
    }

    public init(role: Role, content: String, toolCall: ToolCall? = nil, toolResult: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolCall = toolCall
        self.toolResult = toolResult
    }
}
