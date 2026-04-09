import Foundation

// MARK: - Built-in Tools

/// Returns current date and time
public struct DateTimeTool: AgentTool {
    public let id = "get_datetime"
    public let name = "get_datetime"
    public let description = "Get the current date and time"
    public let parametersSchema = "{}"

    public init() {}

    public func execute(parameters: String) async throws -> ToolResult {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss (EEEE)"
        formatter.locale = Locale(identifier: "vi_VN")
        return .success(formatter.string(from: Date()))
    }
}

/// Basic math calculator
public struct CalculatorTool: AgentTool {
    public let id = "calculate"
    public let name = "calculate"
    public let description = "Evaluate a math expression. Use for any calculations."
    public let parametersSchema = """
    {"expression": "string - math expression to evaluate, e.g. '2+3*4'"}
    """

    public init() {}

    public func execute(parameters: String) async throws -> ToolResult {
        guard let data = parameters.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expression = json["expression"] as? String else {
            return .error("Invalid parameters. Expected {\"expression\": \"...\"}")
        }

        // Use NSExpression for safe math evaluation
        let sanitized = expression.replacingOccurrences(of: "[^0-9+\\-*/().,%^ ]", with: "", options: .regularExpression)
        let nsExpression = NSExpression(format: sanitized)
        if let result = nsExpression.expressionValue(with: nil, context: nil) as? NSNumber {
            return .success("\(expression) = \(result)")
        }
        return .error("Could not evaluate expression: \(expression)")
    }
}

/// Text search tool (searches in provided context)
public struct TextSearchTool: AgentTool {
    public let id = "search_text"
    public let name = "search_text"
    public let description = "Search for a keyword or phrase in the conversation context or memory"
    public let parametersSchema = """
    {"query": "string - search query"}
    """

    private let searchFunction: @Sendable (String) async -> String

    public init(searchFunction: @escaping @Sendable (String) async -> String) {
        self.searchFunction = searchFunction
    }

    public func execute(parameters: String) async throws -> ToolResult {
        guard let data = parameters.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String else {
            return .error("Invalid parameters. Expected {\"query\": \"...\"}")
        }
        let result = await searchFunction(query)
        return result.isEmpty ? .error("No results found for: \(query)") : .success(result)
    }
}
