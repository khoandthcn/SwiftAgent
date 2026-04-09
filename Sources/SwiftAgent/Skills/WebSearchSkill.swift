import Foundation

// MARK: - Web Search Skill
//
// Provides web search capability via a configurable search provider.
// Default: DuckDuckGo HTML (no API key needed, works on-device).
// Can be extended with Google/Bing APIs.

public struct WebSearchSkill: AgentSkill {
    public let id = "web_search"
    public let name = "Web Search"
    public let description = "Search the web for information"
    public let tools: [any AgentTool]
    public let triggerKeywords = [
        "search", "tìm kiếm", "google", "web",
        "tra cứu", "look up", "what is", "là gì",
        "tin tức", "news", "latest", "mới nhất",
        "how to", "cách", "hướng dẫn"
    ]
    public let priority: Int = 3

    public let systemPromptExtension = """
    You can search the web for up-to-date information. Use web_search when the user asks about current events, factual questions you're unsure about, or anything requiring recent data.
    """

    public init(searcher: WebSearcher? = nil) {
        let search = searcher ?? DuckDuckGoSearcher()
        self.tools = [
            WebSearchTool(searcher: search),
            FetchURLTool(),
        ]
    }
}

// MARK: - Web Searcher Protocol

public protocol WebSearcher: Sendable {
    func search(query: String, limit: Int) async throws -> [WebSearchResult]
}

public struct WebSearchResult: Codable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

// MARK: - DuckDuckGo Searcher (no API key needed)

public final class DuckDuckGoSearcher: WebSearcher, @unchecked Sendable {

    public init() {}

    public func search(query: String, limit: Int = 5) async throws -> [WebSearchResult] {
        // Use DuckDuckGo HTML search (no API key required)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        return parseResults(html: html, limit: limit)
    }

    private func parseResults(html: String, limit: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []

        // Simple HTML parsing for DuckDuckGo results
        let resultPattern = "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
        let snippetPattern = "<a[^>]*class=\"result__snippet\"[^>]*>([^<]+)</a>"

        let resultRegex = try? NSRegularExpression(pattern: resultPattern)
        let snippetRegex = try? NSRegularExpression(pattern: snippetPattern)

        let resultMatches = resultRegex?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
        let snippetMatches = snippetRegex?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []

        for (i, match) in resultMatches.prefix(limit).enumerated() {
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }

            let resultURL = String(html[urlRange])
                .replacingOccurrences(of: "//duckduckgo.com/l/?uddg=", with: "")
                .removingPercentEncoding ?? ""

            let title = String(html[titleRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var snippet = ""
            if i < snippetMatches.count,
               let snippetRange = Range(snippetMatches[i].range(at: 1), in: html) {
                snippet = String(html[snippetRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !title.isEmpty {
                results.append(WebSearchResult(title: title, url: resultURL, snippet: snippet))
            }
        }

        return results
    }
}

// MARK: - Web Search Tool

final class WebSearchTool: AgentTool, @unchecked Sendable {
    let id = "web_search"
    let name = "web_search"
    let description = "Search the web. Returns titles, URLs, and snippets."
    let parametersSchema = """
    {"query": "string - search query"}
    """

    private let searcher: any WebSearcher

    init(searcher: any WebSearcher) { self.searcher = searcher }

    func execute(parameters: String) async throws -> ToolResult {
        guard let data = parameters.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String else {
            return .error("Expected {\"query\": \"search term\"}")
        }

        do {
            let results = try await searcher.search(query: query, limit: 5)
            if results.isEmpty {
                return .success("No results found for '\(query)'.")
            }
            let formatted = results.enumerated().map { idx, r in
                "\(idx + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
            }.joined(separator: "\n\n")
            return .success("Search results for '\(query)':\n\n\(formatted)")
        } catch {
            return .error("Web search failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Fetch URL Tool

final class FetchURLTool: AgentTool, @unchecked Sendable {
    let id = "fetch_url"
    let name = "fetch_url"
    let description = "Fetch and extract text content from a URL. Use after web_search to read a page."
    let parametersSchema = """
    {"url": "string - the URL to fetch"}
    """

    func execute(parameters: String) async throws -> ToolResult {
        guard let data = parameters.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            return .error("Expected {\"url\": \"https://...\"}")
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (responseData, _) = try await URLSession.shared.data(for: request)
            var text = String(data: responseData, encoding: .utf8) ?? ""

            // Strip HTML tags for readability
            text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Limit to 2000 chars
            if text.count > 2000 {
                text = String(text.prefix(2000)) + "..."
            }

            return .success("Content from \(urlString):\n\n\(text)")
        } catch {
            return .error("Failed to fetch URL: \(error.localizedDescription)")
        }
    }
}
