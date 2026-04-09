import Foundation

// MARK: - Soul System
//
// Inspired by OpenClaw's SOUL.md + CoPaw's PROFILE.md.
//
// The Soul defines WHO the agent is: identity, personality, values, boundaries,
// communication style, and knowledge areas. It is loaded at session start and
// injected into every prompt, shaping all agent behavior.
//
// Key design principle: "it reads itself into being" — the agent's personality
// is a configuration, not hardcoded logic. Change the Soul, change the agent.
//
// Format: structured Swift config (not markdown) for type safety and validation.
// Can be serialized to/from JSON for persistence and editing.

// MARK: - Soul Definition

public struct Soul: Codable, Sendable {

    /// Agent's core identity
    public var identity: Identity

    /// Communication style rules
    public var style: CommunicationStyle

    /// Values and decision-making principles
    public var values: [String]

    /// Hard boundaries — things the agent must NEVER do
    public var boundaries: [String]

    /// Knowledge domains and expertise areas
    public var knowledgeAreas: [String]

    /// Custom instructions (freeform, appended to system prompt)
    public var customInstructions: String

    // MARK: - Identity

    public struct Identity: Codable, Sendable {
        /// Agent's name
        public var name: String

        /// Role description (e.g., "personal meeting assistant")
        public var role: String

        /// Core personality traits
        public var traits: [String]

        /// Brief self-description (1-2 sentences)
        public var description: String

        public init(
            name: String = "Agent",
            role: String = "helpful personal AI assistant",
            traits: [String] = ["helpful", "concise", "honest"],
            description: String = ""
        ) {
            self.name = name
            self.role = role
            self.traits = traits
            self.description = description
        }
    }

    // MARK: - Communication Style

    public struct CommunicationStyle: Codable, Sendable {
        /// Primary language (e.g., "vi" for Vietnamese)
        public var language: String

        /// Formality level: casual, neutral, formal
        public var formality: Formality

        /// Response length preference
        public var verbosity: Verbosity

        /// Whether to use emoji
        public var useEmoji: Bool

        /// Custom style notes (e.g., "use markdown for lists")
        public var notes: String

        public enum Formality: String, Codable, Sendable, CaseIterable {
            case casual, neutral, formal
        }

        public enum Verbosity: String, Codable, Sendable, CaseIterable {
            case concise, balanced, detailed
        }

        public init(
            language: String = "vi",
            formality: Formality = .neutral,
            verbosity: Verbosity = .concise,
            useEmoji: Bool = false,
            notes: String = ""
        ) {
            self.language = language
            self.formality = formality
            self.verbosity = verbosity
            self.useEmoji = useEmoji
            self.notes = notes
        }
    }

    // MARK: - Init

    public init(
        identity: Identity = Identity(),
        style: CommunicationStyle = CommunicationStyle(),
        values: [String] = [],
        boundaries: [String] = [],
        knowledgeAreas: [String] = [],
        customInstructions: String = ""
    ) {
        self.identity = identity
        self.style = style
        self.values = values
        self.boundaries = boundaries
        self.knowledgeAreas = knowledgeAreas
        self.customInstructions = customInstructions
    }

    // MARK: - Default Souls

    /// Default Vietnamese personal assistant soul
    public static let vietnameseAssistant = Soul(
        identity: Identity(
            name: "Gemma",
            role: "trợ lý AI cá nhân chạy trên thiết bị",
            traits: ["thông minh", "ngắn gọn", "thân thiện", "chính xác"],
            description: "Tôi là Gemma, trợ lý AI cá nhân chạy 100% trên thiết bị của bạn. Tôi giúp quản lý cuộc họp, ghi nhớ thông tin, và hỗ trợ công việc hàng ngày."
        ),
        style: CommunicationStyle(
            language: "vi",
            formality: .neutral,
            verbosity: .concise,
            useEmoji: false,
            notes: "Dùng tiếng Việt tự nhiên. Dùng markdown cho danh sách và code. Không dài dòng."
        ),
        values: [
            "Chính xác hơn là nhanh — nếu không chắc chắn thì nói rõ",
            "Bảo mật dữ liệu người dùng — mọi thứ chạy offline trên thiết bị",
            "Hành động cần confirm — luôn hỏi trước khi tạo reminder/event",
            "Ngắn gọn — trả lời thẳng vào vấn đề, không lặp lại câu hỏi"
        ],
        boundaries: [
            "KHÔNG bao giờ bịa thông tin cuộc họp — nếu không tìm thấy thì nói rõ",
            "KHÔNG truy cập dữ liệu ngoài những gì được cung cấp qua tools",
            "KHÔNG thực hiện hành động nguy hiểm (xóa file, gửi tin nhắn) mà không confirm",
            "KHÔNG chia sẻ thông tin cá nhân người dùng"
        ],
        knowledgeAreas: [
            "Quản lý cuộc họp và transcript",
            "Tóm tắt và trích xuất action items",
            "Lịch và nhắc nhở",
            "Hỗ trợ công việc hàng ngày"
        ],
        customInstructions: ""
    )

    // MARK: - Render to System Prompt

    /// Convert Soul to a system prompt string for LLM injection.
    /// This is called at the start of every agent session.
    public func renderSystemPrompt() -> String {
        var prompt = ""

        // Identity
        prompt += "You are \(identity.name), a \(identity.role).\n"
        if !identity.description.isEmpty {
            prompt += "\(identity.description)\n"
        }
        if !identity.traits.isEmpty {
            prompt += "Personality: \(identity.traits.joined(separator: ", ")).\n"
        }
        prompt += "\n"

        // Communication style
        prompt += "COMMUNICATION STYLE:\n"
        prompt += "- Primary language: \(style.language)\n"
        prompt += "- Formality: \(style.formality.rawValue)\n"
        prompt += "- Length: \(style.verbosity.rawValue)\n"
        if !style.notes.isEmpty {
            prompt += "- \(style.notes)\n"
        }
        prompt += "\n"

        // Values
        if !values.isEmpty {
            prompt += "VALUES & PRINCIPLES:\n"
            for value in values {
                prompt += "- \(value)\n"
            }
            prompt += "\n"
        }

        // Boundaries (critical — must be enforced)
        if !boundaries.isEmpty {
            prompt += "BOUNDARIES (NEVER VIOLATE):\n"
            for boundary in boundaries {
                prompt += "- \(boundary)\n"
            }
            prompt += "\n"
        }

        // Knowledge areas
        if !knowledgeAreas.isEmpty {
            prompt += "EXPERTISE:\n"
            for area in knowledgeAreas {
                prompt += "- \(area)\n"
            }
            prompt += "\n"
        }

        // Custom instructions
        if !customInstructions.isEmpty {
            prompt += customInstructions + "\n"
        }

        return prompt
    }

    // MARK: - Persistence

    /// Save soul to JSON file
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }

    /// Load soul from JSON file
    public static func load(from url: URL) throws -> Soul {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Soul.self, from: data)
    }
}
