import Foundation

// MARK: - Mail Skill
//
// Gives the agent ability to search, read, and send emails via IMAP/SMTP.

public struct MailSkill: AgentSkill {
    public let id = "mail"
    public let name = "Email"
    public let description = "Search, read, and send emails"
    public let tools: [any AgentTool]
    public let triggerKeywords = [
        "email", "mail", "inbox", "hộp thư",
        "gửi mail", "send email", "đọc mail", "read email",
        "thư", "reply", "trả lời", "forward", "chuyển tiếp"
    ]
    public let priority: Int = 4

    public let systemPromptExtension = """
    You have access to the user's email. You can search, read, and send emails.
    IMPORTANT: Always confirm with the user before sending an email.
    When reading emails, summarize the key points concisely.
    """

    public init(mailService: MailService) {
        self.tools = [
            SearchEmailTool(mailService: mailService),
            ReadEmailTool(mailService: mailService),
            SendEmailTool(mailService: mailService),
            ListRecentEmailsTool(mailService: mailService),
        ]
    }
}

// MARK: - Search Email Tool

final class SearchEmailTool: AgentTool, @unchecked Sendable {
    let id = "search_email"
    let name = "search_email"
    let description = "Search emails by keyword in subject or sender. Returns list of matching emails."
    let parametersSchema = """
    {"query": "string - search keyword", "folder": "string (optional) - folder name, default INBOX"}
    """

    private let mailService: MailService

    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        guard let json = parseMailJSON(parameters),
              let query = json["query"] as? String else {
            return .error("Expected {\"query\": \"search term\"}")
        }
        let folder = json["folder"] as? String ?? "INBOX"

        do {
            let results = try await mailService.searchEmails(query: query, folder: folder)
            if results.isEmpty {
                return .success("No emails found matching '\(query)' in \(folder).")
            }
            let list = results.map { "- [\($0.date)] From: \($0.from) | Subject: \($0.subject) (uid: \($0.uid))" }
                .joined(separator: "\n")
            return .success("Found \(results.count) emails:\n\(list)")
        } catch {
            return .error("Email search failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Read Email Tool

final class ReadEmailTool: AgentTool, @unchecked Sendable {
    let id = "read_email"
    let name = "read_email"
    let description = "Read the full content of a specific email by its UID. Get UIDs from search_email first."
    let parametersSchema = """
    {"uid": "number - email UID from search results", "folder": "string (optional) - default INBOX"}
    """

    private let mailService: MailService

    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        guard let json = parseMailJSON(parameters),
              let uid = json["uid"] as? Int else {
            return .error("Expected {\"uid\": 12345}")
        }
        let folder = json["folder"] as? String ?? "INBOX"

        do {
            let email = try await mailService.readEmail(uid: uid, folder: folder)
            return .success("""
            From: \(email.from)
            To: \(email.to)
            Subject: \(email.subject)
            Date: \(email.date)

            \(email.body)
            """)
        } catch {
            return .error("Failed to read email: \(error.localizedDescription)")
        }
    }
}

// MARK: - Send Email Tool

final class SendEmailTool: AgentTool, @unchecked Sendable {
    let id = "send_email"
    let name = "send_email"
    let description = "Send an email. ALWAYS confirm with user before calling this tool."
    let parametersSchema = """
    {"to": "string - recipient email", "subject": "string - email subject", "body": "string - email body"}
    """
    let requiresConfirmation = true  // CoPaw: dangerous action requires approval

    private let mailService: MailService

    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        guard let json = parseMailJSON(parameters),
              let to = json["to"] as? String,
              let subject = json["subject"] as? String,
              let body = json["body"] as? String else {
            return .error("Expected {\"to\": \"...\", \"subject\": \"...\", \"body\": \"...\"}")
        }

        do {
            try await mailService.sendEmail(to: to, subject: subject, body: body)
            return .success("Email sent successfully to \(to) with subject '\(subject)'")
        } catch {
            return .error("Failed to send email: \(error.localizedDescription)")
        }
    }
}

// MARK: - List Recent Emails Tool

final class ListRecentEmailsTool: AgentTool, @unchecked Sendable {
    let id = "list_recent_emails"
    let name = "list_recent_emails"
    let description = "List the most recent emails in inbox or specified folder."
    let parametersSchema = """
    {"folder": "string (optional) - default INBOX", "count": "number (optional) - default 10"}
    """

    private let mailService: MailService

    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        let json = parseMailJSON(parameters)
        let folder = json?["folder"] as? String ?? "INBOX"
        let count = json?["count"] as? Int ?? 10

        do {
            let results = try await mailService.getRecentEmails(folder: folder, count: count)
            if results.isEmpty {
                return .success("No emails in \(folder).")
            }
            let list = results.map { "- [\($0.date)] From: \($0.from) | \($0.subject) (uid: \($0.uid))" }
                .joined(separator: "\n")
            return .success("Recent \(results.count) emails in \(folder):\n\(list)")
        } catch {
            return .error("Failed to list emails: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helper

private func parseMailJSON(_ str: String) -> [String: Any]? {
    guard let data = str.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}
