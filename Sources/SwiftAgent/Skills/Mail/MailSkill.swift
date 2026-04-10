import Foundation
import SwiftMail

// MARK: - Mail Skill
//
// Agent-friendly email tools. Agent can freely chain tools to accomplish goals.
// No UID/technical details exposed to user — agent handles everything internally.
//
// Tools designed around user intents, not IMAP operations:
// - check_inbox: "any new mail?" → list recent, highlight unread
// - find_email: "email from John about budget" → search + auto-read
// - reply_email: "reply to John" → find → read → compose → send
// - send_email: "email John about meeting" → compose → send
// - manage_email: "archive that email" / "mark as read" → flag/move

public struct MailSkill: AgentSkill {
    public let id = "mail"
    public let name = "Email"
    public let description = "Full email management: check, search, read, reply, send, organize"
    public let tools: [any AgentTool]
    public let triggerKeywords = [
        "email", "mail", "inbox", "hộp thư",
        "gửi mail", "send", "đọc mail", "read",
        "thư", "reply", "trả lời", "forward",
        "check mail", "kiểm tra", "hộp thư đến",
        "from", "từ", "about", "về", "unread",
        "chưa đọc", "archive", "trash", "xóa"
    ]
    public let priority: Int = 4

    public let systemPromptExtension = """
    EMAIL: You have full access to the user's email.
    - check_inbox: No params needed. Call it when user asks to check mail.
    - find_email: Search by keyword/person/topic. Auto-reads first match.
    - send_email: Compose and send. YOU draft the content. Needs confirmation.
    - manage_email: Mark read/unread, flag, archive, trash.
    Chain tools freely. NEVER ask user for email IDs — find emails by content.
    """

    public init(mailService: MailService) {
        self.tools = [
            CheckInboxTool(mailService: mailService),
            FindEmailTool(mailService: mailService),
            SendEmailTool(mailService: mailService),
            ManageEmailTool(mailService: mailService),
        ]
    }
}

// MARK: - Check Inbox

final class CheckInboxTool: AgentTool, @unchecked Sendable {
    let id = "check_inbox"
    let name = "check_inbox"
    let description = "Check inbox for recent/unread emails. Call without params for a quick overview."
    let parametersSchema = """
    {"unread_only": "bool (optional, default false)", "count": "number (optional, default 10)"}
    """

    private let mailService: MailService
    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        let json = parseJSON(parameters)
        let unreadOnly = json?["unread_only"] as? Bool ?? false
        let count = json?["count"] as? Int ?? 10

        do {
            // Get unread count first
            let unread = try await mailService.unreadCount()

            let emails: [MailMessage]
            if unreadOnly {
                emails = try await mailService.searchEmails(unreadOnly: true, limit: count)
            } else {
                emails = try await mailService.getRecentEmails(count: count)
            }

            if emails.isEmpty {
                return .success(unreadOnly ? "No unread emails." : "Inbox is empty.")
            }

            var response = "\(unread) unread, showing \(emails.count) recent:\n\n"
            for (i, email) in emails.enumerated() {
                let unreadMark = email.isRead ? "  " : "* "
                let flagMark = email.isFlagged ? " [flagged]" : ""
                let attach = email.hasAttachments ? " [attachment]" : ""
                response += "\(unreadMark)\(i+1). \(email.from) — \(email.subject)\(flagMark)\(attach)\n"
                response += "   \(email.date)\n"
            }
            return .success(response)
        } catch {
            return .error("Cannot check inbox: \(error.localizedDescription)")
        }
    }
}

// MARK: - Find Email (search + auto-read)

final class FindEmailTool: AgentTool, @unchecked Sendable {
    let id = "find_email"
    let name = "find_email"
    let description = "Find emails by keyword, person, or topic. Automatically reads the first match. Use for any 'find that email about X' or 'email from Y' request."
    let parametersSchema = """
    {"keyword": "string - search term (person name, topic, any text)", "from": "string (optional) - filter by sender", "unread_only": "bool (optional)"}
    """

    private let mailService: MailService
    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        let json = parseJSON(parameters)
        let keyword = json?["keyword"] as? String
        let fromFilter = json?["from"] as? String
        let unreadOnly = json?["unread_only"] as? Bool ?? false

        guard keyword != nil || fromFilter != nil else {
            return .error("Need at least 'keyword' or 'from' parameter.")
        }

        do {
            let results = try await mailService.searchEmails(
                from: fromFilter,
                keyword: keyword,
                unreadOnly: unreadOnly,
                limit: 5
            )

            if results.isEmpty {
                let query = [keyword, fromFilter].compactMap { $0 }.joined(separator: ", ")
                return .success("No emails found for: \(query)")
            }

            var response = "Found \(results.count) email(s):\n\n"

            // Auto-read first match
            let first = results[0]
            response += "--- Reading first match ---\n"
            response += "From: \(first.from)\n"
            response += "To: \(first.to.joined(separator: ", "))\n"
            response += "Subject: \(first.subject)\n"
            response += "Date: \(first.date)\n"
            response += "Status: \(first.isRead ? "Read" : "Unread")\(first.hasAttachments ? " | Has attachments" : "")\n\n"

            // Try to read full body
            if first.uid > 0 {
                let uid = SwiftMail.UID(UInt32(first.uid))
                do {
                    let full = try await mailService.readEmail(uid: uid)
                    if !full.body.isEmpty {
                        response += "Content:\n\(full.body)\n"
                    }
                } catch {
                    response += "(Could not load full content)\n"
                }
            }

            // List others
            if results.count > 1 {
                response += "\n--- Other matches ---\n"
                for email in results.dropFirst() {
                    let mark = email.isRead ? "" : " [unread]"
                    response += "- \(email.from) — \(email.subject)\(mark) (\(email.date))\n"
                }
            }

            return .success(response)
        } catch {
            return .error("Search failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Send Email

final class SendEmailTool: AgentTool, @unchecked Sendable {
    let id = "send_email"
    let name = "send_email"
    let description = "Send a new email or reply. Draft content yourself based on conversation. Requires user confirmation."
    let parametersSchema = """
    {"to": "string - recipient email", "subject": "string", "body": "string - full email text"}
    """
    let requiresConfirmation = true

    private let mailService: MailService
    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        guard let json = parseJSON(parameters),
              let to = json["to"] as? String,
              let subject = json["subject"] as? String,
              let body = json["body"] as? String else {
            return .error("Need: to, subject, body")
        }

        do {
            try await mailService.sendEmail(to: to, subject: subject, body: body)
            return .success("Sent to \(to)\nSubject: \(subject)")
        } catch {
            return .error("Send failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Manage Email (flag, archive, trash, mark read)

final class ManageEmailTool: AgentTool, @unchecked Sendable {
    let id = "manage_email"
    let name = "manage_email"
    let description = "Manage an email: mark as read/unread, flag, archive, or trash. Find the email first with find_email, then use the email number."
    let parametersSchema = """
    {"action": "string - one of: mark_read, mark_unread, flag, archive, trash", "keyword": "string - search keyword to find the email to act on"}
    """

    private let mailService: MailService
    init(mailService: MailService) { self.mailService = mailService }

    func execute(parameters: String) async throws -> ToolResult {
        guard let json = parseJSON(parameters),
              let action = json["action"] as? String,
              let keyword = json["keyword"] as? String else {
            return .error("Need: action and keyword")
        }

        do {
            // Find email first
            let results = try await mailService.searchEmails(keyword: keyword, limit: 1)
            guard let email = results.first, email.uid > 0 else {
                return .error("Email not found for '\(keyword)'")
            }

            let uid = SwiftMail.UID(UInt32(email.uid))

            switch action {
            case "mark_read":
                try await mailService.markAsRead(uid: uid)
                return .success("Marked as read: \(email.subject)")
            case "mark_unread":
                try await mailService.markAsUnread(uid: uid)
                return .success("Marked as unread: \(email.subject)")
            case "flag":
                try await mailService.flagEmail(uid: uid)
                return .success("Flagged: \(email.subject)")
            case "archive":
                try await mailService.moveEmail(uid: uid, toFolder: "Archive")
                return .success("Archived: \(email.subject)")
            case "trash":
                try await mailService.trashEmail(uid: uid)
                return .success("Trashed: \(email.subject)")
            default:
                return .error("Unknown action: \(action). Use: mark_read, mark_unread, flag, archive, trash")
            }
        } catch {
            return .error("Action failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helper

private func parseJSON(_ str: String) -> [String: Any]? {
    guard let data = str.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}
