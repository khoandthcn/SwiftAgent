import Foundation

// MARK: - General Chat Skill

/// Default skill for general conversation (always available as fallback)
public struct GeneralChatSkill: AgentSkill {
    public let id = "general_chat"
    public let name = "General Chat"
    public let description = "General conversation and Q&A"
    public let tools: [any AgentTool] = [DateTimeTool(), CalculatorTool()]
    public let triggerKeywords: [String] = []  // always available as fallback
    public let priority: Int = -1  // lowest priority, fallback only

    public init() {}
}

// MARK: - Meeting Skill (example for VoiceMeetAI integration)

/// Skill for querying meeting transcripts, summaries, and action items.
/// Host app provides the search/query tools.
public struct MeetingSkill: AgentSkill {
    public let id = "meeting"
    public let name = "Meeting Assistant"
    public let description = "Search and query meeting transcripts, summaries, and action items"
    public let tools: [any AgentTool]
    public let triggerKeywords = [
        "meeting", "cuộc họp", "transcript", "bản ghi",
        "summary", "tóm tắt", "action item", "việc cần làm",
        "ai nói", "who said", "quyết định", "decision",
        "hôm qua", "tuần trước", "last week"
    ]
    public let priority: Int = 5

    public let systemPromptExtension = """
    You have access to meeting data. When the user asks about meetings, use the search tools to find relevant information before answering. Always cite which meeting the information comes from.
    """

    /// Create MeetingSkill with host-app-provided tools
    public init(tools: [any AgentTool]) {
        self.tools = tools
    }
}

// MARK: - Reminder Skill (example for iOS integration)

/// Skill for creating reminders and calendar events.
/// Host app provides the EventKit-based tools.
public struct ReminderSkill: AgentSkill {
    public let id = "reminder"
    public let name = "Reminders & Calendar"
    public let description = "Create reminders, calendar events, and manage schedules"
    public let tools: [any AgentTool]
    public let triggerKeywords = [
        "nhắc", "reminder", "lịch", "calendar", "hẹn", "schedule",
        "deadline", "hạn", "ngày mai", "tomorrow", "tuần tới", "next week"
    ]
    public let priority: Int = 4

    public let systemPromptExtension = """
    You can create reminders and calendar events. When the user asks to be reminded about something or to schedule something, use the appropriate tool. Always confirm the details before creating.
    """

    public init(tools: [any AgentTool]) {
        self.tools = tools
    }
}
