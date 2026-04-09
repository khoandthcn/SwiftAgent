import Foundation

// MARK: - In-Memory Store
//
// Simple in-memory implementation of MemoryStore.
// For production, replace with persistent store (SQLite, ObjectBox, etc.)

public actor InMemoryStore: MemoryStore {

    private var entries: [MemoryEntry] = []

    public init() {}

    public func store(_ entry: MemoryEntry) {
        // Deduplicate: don't store if very similar content exists
        let isDuplicate = entries.contains { existing in
            existing.content == entry.content ||
            (existing.type == entry.type && similarity(existing.content, entry.content) > 0.8)
        }
        guard !isDuplicate else { return }
        entries.append(entry)
    }

    public func retrieve(query: String, limit: Int) -> [MemoryEntry] {
        // Simple keyword-based retrieval (for production, use vector similarity)
        let queryWords = Set(query.lowercased().components(separatedBy: .whitespaces).filter { $0.count > 2 })

        let scored = entries.map { entry -> (entry: MemoryEntry, score: Float) in
            let entryWords = Set(entry.content.lowercased().components(separatedBy: .whitespaces))
            let overlap = Float(queryWords.intersection(entryWords).count)
            let score = overlap * entry.relevanceScore
            return (entry, score)
        }

        return scored
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.entry }
    }

    public func getByType(_ type: MemoryEntry.MemoryType, limit: Int) -> [MemoryEntry] {
        entries.filter { $0.type == type }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public func count() -> Int {
        entries.count
    }

    public func compact(maxEntries: Int) {
        guard entries.count > maxEntries else { return }
        // Keep most relevant + most recent
        entries.sort { ($0.relevanceScore * 10 + Float($0.accessCount)) > ($1.relevanceScore * 10 + Float($1.accessCount)) }
        entries = Array(entries.prefix(maxEntries))
    }

    // MARK: - Simple string similarity (Jaccard)

    private func similarity(_ a: String, _ b: String) -> Float {
        let setA = Set(a.lowercased().components(separatedBy: .whitespaces))
        let setB = Set(b.lowercased().components(separatedBy: .whitespaces))
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 ? Float(intersection) / Float(union) : 0
    }
}
