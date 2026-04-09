import Foundation

// MARK: - Skill Router
//
// Routes user messages to relevant skills based on keyword matching
// and contextual relevance. Lightweight — no ML, just string matching.
// For production, could be upgraded to use embeddings-based routing.

final class SkillRouter: @unchecked Sendable {

    private struct SkillEntry {
        let id: String
        let keywords: [String]
        let priority: Int
    }

    private var entries: [SkillEntry] = []
    private var skillMap: [String: any AgentSkill] = [:]

    func register(_ skill: any AgentSkill) {
        entries.append(SkillEntry(
            id: skill.id,
            keywords: skill.triggerKeywords.map { $0.lowercased() },
            priority: skill.priority
        ))
        skillMap[skill.id] = skill
    }

    func route(message: String, allSkills: [any AgentSkill]) -> [any AgentSkill] {
        let lower = message.lowercased()

        // Score each skill by keyword matches
        var scored: [(skill: any AgentSkill, score: Int)] = []
        for entry in entries {
            let matchCount = entry.keywords.filter { lower.contains($0) }.count
            if matchCount > 0, let skill = skillMap[entry.id] {
                scored.append((skill, matchCount + entry.priority))
            }
        }

        if scored.isEmpty {
            // No keyword match — return top 2 skills by priority as fallback
            return Array(allSkills.sorted { $0.priority > $1.priority }.prefix(2))
        }

        // Return matched skills sorted by score
        return scored.sorted { $0.score > $1.score }.map { $0.skill }
    }
}
