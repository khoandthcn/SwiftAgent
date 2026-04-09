import Foundation

// MARK: - Memory Manager
//
// Three-tier memory system (inspired by CoPaw + Mem0):
//
// Hot:  Current conversation context (in prompt window) — managed by Agent
// Warm: Extracted facts/entities stored in MemoryStore — fast retrieval
// Cold: Raw conversation history — stored externally (SwiftData by host app)
//
// The MemoryManager handles warm tier: extraction, storage, retrieval, compaction.

actor MemoryManager {

    private let store: any MemoryStore
    private let maxWarmEntries: Int

    init(store: any MemoryStore, maxWarmEntries: Int = 500) {
        self.store = store
        self.maxWarmEntries = maxWarmEntries
    }

    // MARK: - Retrieval

    /// Retrieve relevant memories for a query (for prompt building)
    func retrieveRelevant(for query: String, limit: Int = 5) async -> [MemoryEntry] {
        await store.retrieve(query: query, limit: limit)
    }

    // MARK: - Extraction

    /// Extract facts/entities from recent conversation and store them.
    /// Called asynchronously after each agent response.
    func extractAndStore(from messages: some Collection<AgentMessage>) async {
        for msg in messages {
            // Extract from user messages (preferences, facts about themselves)
            if msg.role == .user {
                let facts = extractFacts(from: msg.content)
                for fact in facts {
                    await store.store(fact)
                }
            }

            // Extract from tool results (action items, meeting info)
            if msg.role == .tool, let result = msg.toolResult {
                if result.contains("action") || result.contains("reminder") || result.contains("todo") {
                    let entry = MemoryEntry(content: result, type: .actionItem, relevanceScore: 0.8)
                    await store.store(entry)
                }
            }
        }

        // Compact if over limit
        let count = await store.count()
        if count > maxWarmEntries {
            await store.compact(maxEntries: maxWarmEntries)
        }
    }

    // MARK: - Manual Memory

    func addMemory(_ content: String, type: MemoryEntry.MemoryType) async {
        let entry = MemoryEntry(content: content, type: type)
        await store.store(entry)
    }

    func clearAll() async {
        await store.compact(maxEntries: 0)
    }

    // MARK: - Fact Extraction (lightweight, no LLM needed)

    private func extractFacts(from text: String) -> [MemoryEntry] {
        var facts: [MemoryEntry] = []
        let lower = text.lowercased()

        // Detect preference statements
        let preferencePatterns = [
            "tôi thích", "tôi muốn", "tôi cần", "tôi hay",
            "i prefer", "i like", "i want", "i need",
            "luôn luôn", "không bao giờ", "thường xuyên"
        ]
        for pattern in preferencePatterns {
            if lower.contains(pattern) {
                facts.append(MemoryEntry(content: text, type: .preference, relevanceScore: 0.9))
                break
            }
        }

        // Detect entity introductions
        let entityPatterns = [
            "tên tôi là", "tôi là", "my name is", "i am",
            "anh ấy là", "chị ấy là", "là trưởng", "là giám đốc", "là manager"
        ]
        for pattern in entityPatterns {
            if lower.contains(pattern) {
                facts.append(MemoryEntry(content: text, type: .entity, relevanceScore: 0.95))
                break
            }
        }

        return facts
    }
}
