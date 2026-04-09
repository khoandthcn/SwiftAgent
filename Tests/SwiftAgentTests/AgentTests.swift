import Testing
import Foundation
@testable import SwiftAgent

// MARK: - Mock LLM Backend

struct MockLLMBackend: LLMBackend {
    var responses: [String] = ["Hello! How can I help you?"]
    var responseIndex: Int = 0
    var isReady: Bool = true
    var contextSize: Int = 4096

    mutating func nextResponse() -> String {
        let r = responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
        return r
    }

    func generate(prompt: String, maxTokens: Int, temperature: Float) async -> String {
        responses.first ?? ""
    }

    func generateStream(prompt: String, maxTokens: Int, temperature: Float) -> AsyncStream<String> {
        let response = responses.first ?? ""
        return AsyncStream { continuation in
            for word in response.components(separatedBy: " ") {
                continuation.yield(word + " ")
            }
            continuation.finish()
        }
    }

    func countTokens(_ text: String) -> Int {
        text.count / 3
    }
}

// MARK: - Mock Tool

struct MockTool: AgentTool {
    let id: String
    let name: String
    let description: String
    let parametersSchema = "{}"
    var resultToReturn: ToolResult = .success("Mock result")

    func execute(parameters: String) async throws -> ToolResult {
        resultToReturn
    }
}

// MARK: - Tests

@Suite("Agent Core")
struct AgentCoreTests {

    @Test("Agent processes simple message")
    func simpleMessage() async {
        let llm = MockLLMBackend(responses: ["Xin chào! Tôi có thể giúp gì cho bạn?"])
        let agent = Agent(llm: llm)
        let response = await agent.processMessage("Hello")
        #expect(!response.isEmpty)
    }

    @Test("Agent maintains conversation history")
    func conversationHistory() async {
        let llm = MockLLMBackend(responses: ["Response 1"])
        let agent = Agent(llm: llm)
        _ = await agent.processMessage("Message 1")
        let history = await agent.getHistory()
        #expect(history.count == 2) // user + assistant
        #expect(history[0].role == .user)
        #expect(history[1].role == .assistant)
    }

    @Test("Agent clears history")
    func clearHistory() async {
        let llm = MockLLMBackend(responses: ["Hi"])
        let agent = Agent(llm: llm)
        _ = await agent.processMessage("Hello")
        await agent.clearHistory()
        let history = await agent.getHistory()
        #expect(history.isEmpty)
    }
}

@Suite("Tool System")
struct ToolTests {

    @Test("DateTimeTool returns current date")
    func dateTimeTool() async throws {
        let tool = DateTimeTool()
        let result = try await tool.execute(parameters: "{}")
        #expect(!result.isError)
        #expect(!result.content.isEmpty)
    }

    @Test("CalculatorTool evaluates expression")
    func calculatorTool() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: "{\"expression\": \"2+3*4\"}")
        #expect(!result.isError)
        #expect(result.content.contains("14"))
    }

    @Test("CalculatorTool handles invalid input")
    func calculatorInvalidInput() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: "not json")
        #expect(result.isError)
    }

    @Test("ToolResult factory methods")
    func toolResultFactories() {
        let success = ToolResult.success("ok")
        #expect(!success.isError)
        #expect(success.content == "ok")

        let error = ToolResult.error("fail")
        #expect(error.isError)
        #expect(error.content == "fail")
    }
}

@Suite("Skill System")
struct SkillTests {

    @Test("GeneralChatSkill has built-in tools")
    func generalChatSkill() {
        let skill = GeneralChatSkill()
        #expect(skill.tools.count == 2) // DateTime + Calculator
        #expect(skill.priority == -1) // lowest, fallback
    }

    @Test("MeetingSkill has trigger keywords")
    func meetingSkillKeywords() {
        let skill = MeetingSkill(tools: [])
        #expect(!skill.triggerKeywords.isEmpty)
        #expect(skill.triggerKeywords.contains("cuộc họp"))
        #expect(skill.triggerKeywords.contains("meeting"))
    }

    @Test("ReminderSkill has trigger keywords")
    func reminderSkillKeywords() {
        let skill = ReminderSkill(tools: [])
        #expect(skill.triggerKeywords.contains("nhắc"))
        #expect(skill.triggerKeywords.contains("calendar"))
    }

    @Test("Skill registration on agent")
    func skillRegistration() async {
        let llm = MockLLMBackend()
        let agent = Agent(llm: llm)
        await agent.registerSkill(GeneralChatSkill())
        await agent.registerSkill(MeetingSkill(tools: []))
        // Skills registered — agent should still work
        let response = await agent.processMessage("test")
        #expect(!response.isEmpty)
    }
}

@Suite("Memory System")
struct MemoryTests {

    @Test("InMemoryStore stores and retrieves")
    func storeAndRetrieve() async {
        let store = InMemoryStore()
        let entry = MemoryEntry(content: "User prefers Vietnamese language", type: .preference)
        await store.store(entry)
        let count = await store.count()
        #expect(count == 1)

        let results = await store.retrieve(query: "Vietnamese language", limit: 5)
        #expect(results.count == 1)
        #expect(results[0].content.contains("Vietnamese"))
    }

    @Test("InMemoryStore deduplicates")
    func deduplication() async {
        let store = InMemoryStore()
        let entry1 = MemoryEntry(content: "User likes coffee", type: .preference)
        let entry2 = MemoryEntry(content: "User likes coffee", type: .preference)
        await store.store(entry1)
        await store.store(entry2)
        let count = await store.count()
        #expect(count == 1) // deduplicated
    }

    @Test("InMemoryStore compacts")
    func compaction() async {
        let store = InMemoryStore()
        for i in 0..<20 {
            await store.store(MemoryEntry(content: "Fact \(i)", type: .fact))
        }
        #expect(await store.count() == 20)
        await store.compact(maxEntries: 5)
        #expect(await store.count() == 5)
    }

    @Test("InMemoryStore filters by type")
    func filterByType() async {
        let store = InMemoryStore()
        await store.store(MemoryEntry(content: "Preference 1", type: .preference))
        await store.store(MemoryEntry(content: "Fact 1", type: .fact))
        await store.store(MemoryEntry(content: "Entity 1", type: .entity))

        let preferences = await store.getByType(.preference, limit: 10)
        #expect(preferences.count == 1)
        #expect(preferences[0].type == .preference)
    }

    @Test("MemoryEntry types are codable")
    func memoryCodable() throws {
        let entry = MemoryEntry(content: "Test", type: .fact)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MemoryEntry.self, from: data)
        #expect(decoded.content == "Test")
        #expect(decoded.type == .fact)
    }
}

@Suite("AgentMessage")
struct AgentMessageTests {

    @Test("Message creation")
    func messageCreation() {
        let msg = AgentMessage(role: .user, content: "Hello")
        #expect(msg.role == .user)
        #expect(msg.content == "Hello")
        #expect(msg.toolCall == nil)
    }

    @Test("Message with tool call")
    func messageWithToolCall() {
        let call = AgentMessage.ToolCall(toolName: "get_datetime", parameters: "{}")
        let msg = AgentMessage(role: .assistant, content: "Let me check", toolCall: call)
        #expect(msg.toolCall?.toolName == "get_datetime")
    }

    @Test("Messages are codable")
    func messageCodable() throws {
        let msg = AgentMessage(role: .user, content: "Test message")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        #expect(decoded.content == "Test message")
        #expect(decoded.role == .user)
    }
}
