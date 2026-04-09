import Foundation

// MARK: - Mail Skill
//
// Agent-friendly email tools. Designed so the agent can:
// 1. "check my email" → list_recent_emails → summarize
// 2. "any email from John?" → find_email(from:"John") → read content
// 3. "what did that email about budget say?" → find_email(keyword:"budget") → read content
// 4. "reply to John's email" → find → read → draft → send (with confirmation)
//
// Key design: NO UID exposed to user. find_email auto-reads first match.

public struct MailSkill: AgentSkill {
    public let id = "mail"
    public let name = "Email"
    public let description = "Search, read, and send emails"
    public let tools: [any AgentTool]
    public let triggerKeywords = [
        "email", "mail", "inbox", "hộp thư",
        "gửi mail", "send email", "đọc mail", "read email",
        "thư", "reply", "trả lời", "forward", "chuyển tiếp",
        "check mail", "kiểm tra mail", "hộp thư đến",
        "from", "từ", "about", "về"
    ]
    public let priority: Int = 4

    public let systemPromptExtension = """
    EMAIL TOOLS - use them freely, chain multiple calls:
    1. check_inbox: See recent emails. Use when user says "check mail" or "any new email?"
    2. find_email: Search + auto-read first match. Use when user asks about a specific email.
    3. send_email: Send email (requires user confirmation). Draft the email content yourself.
    Do NOT ask the user for email IDs or UIDs — handle that internally.
    """

    public init(mailService: MailService) {
        self.tools = [
            CheckInboxTool(mailService: mailService),
            FindEmailTool(mailService: mailService),
            SendEmailTool(mailService: mailService),
        ]
    }
}

// MARK: - Check Inbox (list recent, no params needed)

final class CheckInboxTool: AgentTool, @unchecked Sendable {
    let id = "check_inbox"
    let name = "check_inbox"
    let description = "Check inbox for recent emails. No parameters needed. Returns latest 10 emails with sender, subject, date."
    let parametersSchema = """
    {"count": "number (optional, default 10)"}
    """

    private let mailService: MailService
    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        let json = parseMailJSON(parameters)
        let count = json?["count"] as? Int ?? 10

        do {
            let results = try await mailService.getRecentEmails(folder: "INBOX", count: count)
            if results.isEmpty {
                return .success("Inbox is empty.")
            }
            let list = results.enumerated().map { idx, email in
                "\(idx + 1). From: \(email.from) | Subject: \(email.subject) | \(email.date)"
            }.joined(separator: "\n")
            return .success("\(results.count) recent emails:\n\(list)")
        } catch {
            return .error("Cannot check inbox: \(error.localizedDescription)")
        }
    }
}

// MARK: - Find Email (search + auto-read first match)

final class FindEmailTool: AgentTool, @unchecked Sendable {
    let id = "find_email"
    let name = "find_email"
    let description = "Find and read an email by keyword (searches subject and sender). Automatically reads the first matching email. Use when user asks about a specific email."
    let parametersSchema = """
    {"keyword": "string - search in subject/sender, e.g. person name, topic, keyword"}
    """

    private let mailService: MailService
    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        guard let json = parseMailJSON(parameters),
              let keyword = json["keyword"] as? String else {
            return .error("Expected {\"keyword\": \"search term\"}")
        }

        do {
            let results = try await mailService.searchEmails(query: keyword, folder: "INBOX", limit: 5)

            if results.isEmpty {
                return .success("No emails found matching '\(keyword)'.")
            }

            // Build summary of all matches
            var response = "Found \(results.count) email(s) matching '\(keyword)':\n\n"

            // Auto-read first match (most relevant)
            let first = results[0]
            response += "--- First Match ---\n"
            response += "From: \(first.from)\n"
            response += "Subject: \(first.subject)\n"
            response += "Date: \(first.date)\n"

            // Try to read full content of first match
            if first.uid > 0 {
                do {
                    let full = try await mailService.readEmail(uid: first.uid, folder: "INBOX")
                    if !full.body.isEmpty && full.body != "(Full body fetch requires message set — showing summary)" {
                        response += "Content:\n\(full.body)\n"
                    }
                } catch {
                    // Read failed — show what we have
                }
            }

            // List others if more than 1
            if results.count > 1 {
                response += "\n--- Other Matches ---\n"
                for email in results.dropFirst() {
                    response += "- From: \(email.from) | \(email.subject) | \(email.date)\n"
                }
            }

            return .success(response)
        } catch {
            return .error("Email search failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Send Email (with confirmation)

final class SendEmailTool: AgentTool, @unchecked Sendable {
    let id = "send_email"
    let name = "send_email"
    let description = "Send an email. Draft the content yourself based on conversation. Requires user confirmation before sending."
    let parametersSchema = """
    {"to": "string - recipient email address", "subject": "string - email subject", "body": "string - full email body text"}
    """
    let requiresConfirmation = true

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
            return .success("Email sent to \(to)\nSubject: \(subject)")
        } catch {
            return .error("Send failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helper

private func parseMailJSON(_ str: String) -> [String: Any]? {
    guard let data = str.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}
