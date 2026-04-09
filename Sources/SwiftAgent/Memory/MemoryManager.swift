import Foundation

// MARK: - Memory Manager
//
// Three-tier memory system inspired by CoPaw's ReMe + Mem0 architecture:
//
// Hot:  Current conversation context — in prompt window, managed by Agent
// Warm: Extracted facts, preferences, entities — fast retrieval via MemoryStore
// Cold: Raw conversation history — stored externally by host app
//
// CoPaw-inspired features:
// - PROFILE: Accumulated user preferences and working context (like CoPaw's PROFILE.md)
// - Compression: Old memories are summarized into fewer, denser entries
// - Decay: Relevance scores decrease over time; unused memories are forgotten
// - Proactive search: Agent can search memories before answering

public actor MemoryManager {

    private let store: any MemoryStore
    private let maxWarmEntries: Int
    private let decayRate: Float       // how fast memories lose relevance (per day)
    private let compressionThreshold: Int  // compress when exceeding this count

    // User profile — accumulated preferences (CoPaw's PROFILE.md equivalent)
    private(set) var userProfile: UserProfile = UserProfile()

    public init(
        store: any MemoryStore,
        maxWarmEntries: Int = 500,
        decayRate: Float = 0.02,        // lose 2% relevance per day
        compressionThreshold: Int = 400  // compress at 400 to stay under 500
    ) {
        self.store = store
        self.maxWarmEntries = maxWarmEntries
        self.decayRate = decayRate
        self.compressionThreshold = compressionThreshold
    }

    // MARK: - Retrieval (for prompt building)

    /// Retrieve relevant memories + user profile context for a query
    public func buildContext(for query: String, limit: Int = 5) async -> String {
        var context = ""

        // User profile summary
        let profileSummary = userProfile.renderForPrompt()
        if !profileSummary.isEmpty {
            context += "USER PROFILE:\n\(profileSummary)\n\n"
        }

        // Relevant warm memories
        let memories = await store.retrieve(query: query, limit: limit)
        if !memories.isEmpty {
            context += "RELEVANT CONTEXT:\n"
            for mem in memories {
                context += "- [\(mem.type.rawValue)] \(mem.content)\n"
            }
        }

        return context
    }

    /// Retrieve raw memories
    public func retrieve(query: String, limit: Int = 5) async -> [MemoryEntry] {
        await store.retrieve(query: query, limit: limit)
    }

    // MARK: - Extraction (after agent response)

    /// Extract and store memories from recent conversation.
    /// Called asynchronously after each agent turn.
    public func extractAndStore(from messages: some Collection<AgentMessage>) async {
        for msg in messages {
            if msg.role == .user {
                let entries = extractFromUserMessage(msg.content)
                for entry in entries {
                    await store.store(entry)
                }
                // Update user profile
                updateProfile(from: msg.content)
            }

            if msg.role == .assistant, let toolResult = msg.toolResult {
                let entries = extractFromToolResult(toolResult)
                for entry in entries {
                    await store.store(entry)
                }
            }
        }

        // Check if compaction needed
        await compactIfNeeded()
    }

    // MARK: - Manual Memory Operations

    public func addMemory(_ content: String, type: MemoryEntry.MemoryType) async {
        await store.store(MemoryEntry(content: content, type: type))
    }

    public func removeMemory(id: UUID) async {
        await store.remove(id: id)
    }

    public func getMemoriesByType(_ type: MemoryEntry.MemoryType, limit: Int = 20) async -> [MemoryEntry] {
        await store.getByType(type, limit: limit)
    }

    public func memoryCount() async -> Int {
        await store.count()
    }

    // MARK: - Decay (Forgetting)

    /// Apply time-based decay to all memories.
    /// Called periodically (e.g., daily or at session start).
    public func applyDecay() async {
        let allFacts = await store.getByType(.fact, limit: 10000)
        let allPrefs = await store.getByType(.preference, limit: 10000)
        let allEntities = await store.getByType(.entity, limit: 10000)

        let now = Date()
        for var entry in allFacts + allPrefs + allEntities {
            let daysSinceCreation = now.timeIntervalSince(entry.createdAt) / 86400
            let decay = decayRate * Float(daysSinceCreation)
            let newScore = max(0.1, entry.relevanceScore - decay)

            // If score drops below threshold and never accessed, forget it
            if newScore < 0.2 && entry.accessCount == 0 {
                await store.remove(id: entry.id)
            } else if abs(newScore - entry.relevanceScore) > 0.01 {
                entry.relevanceScore = newScore
                await store.remove(id: entry.id)
                await store.store(entry)
            }
        }
    }

    // MARK: - Compression

    /// Compact warm memory by removing least relevant entries.
    private func compactIfNeeded() async {
        let count = await store.count()
        if count > compressionThreshold {
            await store.compact(maxEntries: compressionThreshold * 3 / 4) // compact to 75% of threshold
        }
    }

    // MARK: - Profile Management (CoPaw PROFILE.md equivalent)

    private func updateProfile(from message: String) {
        let lower = message.lowercased()

        // Detect and accumulate preferences
        let prefPatterns: [(pattern: String, category: String)] = [
            ("tôi thích", "preferences"), ("i prefer", "preferences"), ("i like", "preferences"),
            ("tôi làm việc", "work_context"), ("i work", "work_context"),
            ("tên tôi", "identity"), ("my name", "identity"),
            ("tôi là", "identity"), ("i am a", "identity"),
        ]

        for (pattern, category) in prefPatterns {
            if lower.contains(pattern) {
                userProfile.addEntry(category: category, content: message)
                break
            }
        }
    }

    public func setProfile(_ profile: UserProfile) {
        self.userProfile = profile
    }

    // MARK: - Fact Extraction

    private func extractFromUserMessage(_ text: String) -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        let lower = text.lowercased()

        // Preferences
        let preferenceKeywords = [
            "tôi thích", "tôi muốn", "tôi cần", "tôi hay",
            "i prefer", "i like", "i want", "i need",
            "luôn luôn", "không bao giờ", "thường xuyên", "always", "never"
        ]
        if preferenceKeywords.contains(where: { lower.contains($0) }) {
            entries.append(MemoryEntry(content: text, type: .preference, relevanceScore: 0.9))
        }

        // Entities (people, roles)
        let entityKeywords = [
            "tên tôi là", "tôi là", "my name is", "i am",
            "anh ấy là", "chị ấy là", "là trưởng", "là giám đốc",
            "là manager", "is the lead", "is responsible for"
        ]
        if entityKeywords.contains(where: { lower.contains($0) }) {
            entries.append(MemoryEntry(content: text, type: .entity, relevanceScore: 0.95))
        }

        return entries
    }

    private func extractFromToolResult(_ result: String) -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        let lower = result.lowercased()

        if lower.contains("action") || lower.contains("todo") || lower.contains("reminder") || lower.contains("nhắc") {
            entries.append(MemoryEntry(content: result, type: .actionItem, relevanceScore: 0.85))
        }

        return entries
    }
}

// MARK: - User Profile (CoPaw PROFILE.md)

public struct UserProfile: Codable, Sendable {
    /// Categorized profile entries
    public var entries: [String: [String]] = [:]

    /// Maximum entries per category
    public var maxPerCategory: Int = 10

    public init() {}

    public mutating func addEntry(category: String, content: String) {
        var list = entries[category] ?? []

        // Deduplicate
        guard !list.contains(content) else { return }

        list.append(content)

        // Trim to max
        if list.count > maxPerCategory {
            list = Array(list.suffix(maxPerCategory))
        }

        entries[category] = list
    }

    /// Render profile for injection into prompt
    public func renderForPrompt() -> String {
        guard !entries.isEmpty else { return "" }
        var result = ""
        for (category, items) in entries.sorted(by: { $0.key < $1.key }) {
            if !items.isEmpty {
                result += "[\(category)]\n"
                for item in items.suffix(3) { // max 3 per category in prompt
                    result += "  - \(item)\n"
                }
            }
        }
        return result
    }

    // MARK: - Persistence

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url)
    }

    public static func load(from url: URL) throws -> UserProfile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }
}
