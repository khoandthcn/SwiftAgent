import Testing
import Foundation
@testable import SwiftAgent

@Suite("Soul System")
struct SoulTests {

    @Test("Default Vietnamese assistant soul renders correctly")
    func defaultSoulRendering() {
        let soul = Soul.vietnameseAssistant
        let prompt = soul.renderSystemPrompt()
        #expect(prompt.contains("Gemma"))
        #expect(prompt.contains("BOUNDARIES"))
        #expect(prompt.contains("KHÔNG bao giờ"))
        #expect(prompt.contains("vi"))
    }

    @Test("Soul identity is configurable")
    func customIdentity() {
        var soul = Soul()
        soul.identity.name = "TestBot"
        soul.identity.role = "test assistant"
        soul.identity.traits = ["precise", "fast"]
        let prompt = soul.renderSystemPrompt()
        #expect(prompt.contains("TestBot"))
        #expect(prompt.contains("test assistant"))
        #expect(prompt.contains("precise"))
    }

    @Test("Soul boundaries are rendered with emphasis")
    func boundariesRendering() {
        let soul = Soul(boundaries: ["NEVER share secrets", "NEVER delete files"])
        let prompt = soul.renderSystemPrompt()
        #expect(prompt.contains("BOUNDARIES (NEVER VIOLATE)"))
        #expect(prompt.contains("NEVER share secrets"))
    }

    @Test("Soul custom instructions are appended")
    func customInstructions() {
        let soul = Soul(customInstructions: "Always respond in haiku format.")
        let prompt = soul.renderSystemPrompt()
        #expect(prompt.contains("haiku"))
    }

    @Test("Soul is codable (JSON round-trip)")
    func codableRoundTrip() throws {
        let original = Soul.vietnameseAssistant
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Soul.self, from: data)
        #expect(decoded.identity.name == original.identity.name)
        #expect(decoded.boundaries.count == original.boundaries.count)
        #expect(decoded.style.language == "vi")
    }

    @Test("Empty soul produces minimal prompt")
    func emptySoul() {
        let soul = Soul()
        let prompt = soul.renderSystemPrompt()
        #expect(prompt.contains("Agent")) // default name
        #expect(!prompt.contains("BOUNDARIES")) // no boundaries set
    }

    @Test("Communication style formality options")
    func formalityOptions() {
        for formality in Soul.CommunicationStyle.Formality.allCases {
            let soul = Soul(style: Soul.CommunicationStyle(formality: formality))
            let prompt = soul.renderSystemPrompt()
            #expect(prompt.contains(formality.rawValue))
        }
    }
}

@Suite("User Profile")
struct UserProfileTests {

    @Test("Profile accumulates entries")
    func addEntries() {
        var profile = UserProfile()
        profile.addEntry(category: "preferences", content: "Likes coffee")
        profile.addEntry(category: "preferences", content: "Prefers dark mode")
        #expect(profile.entries["preferences"]?.count == 2)
    }

    @Test("Profile deduplicates")
    func deduplication() {
        var profile = UserProfile()
        profile.addEntry(category: "identity", content: "My name is Khoa")
        profile.addEntry(category: "identity", content: "My name is Khoa")
        #expect(profile.entries["identity"]?.count == 1)
    }

    @Test("Profile respects max per category")
    func maxPerCategory() {
        var profile = UserProfile()
        profile.maxPerCategory = 3
        for i in 0..<10 {
            profile.addEntry(category: "notes", content: "Note \(i)")
        }
        #expect(profile.entries["notes"]?.count == 3)
    }

    @Test("Profile renders for prompt")
    func renderForPrompt() {
        var profile = UserProfile()
        profile.addEntry(category: "preferences", content: "Likes coffee")
        let rendered = profile.renderForPrompt()
        #expect(rendered.contains("[preferences]"))
        #expect(rendered.contains("Likes coffee"))
    }

    @Test("Profile is codable")
    func codable() throws {
        var profile = UserProfile()
        profile.addEntry(category: "test", content: "value")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserProfile.self, from: data)
        #expect(decoded.entries["test"]?.first == "value")
    }
}
