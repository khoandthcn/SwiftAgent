import Foundation
import SwiftMail

// MARK: - Mail Service
//
// Provides IMAP/SMTP operations using SwiftMail library.
// Used by MailTools to give the agent email access.

public actor MailService {

    private var config: MailAccountConfig?

    public init() {}

    public func configure(_ account: MailAccountConfig) {
        self.config = account
    }

    public var isConfigured: Bool { config != nil }

    // MARK: - List Folders

    public func listFolders() async throws -> [String] {
        guard let config else { throw MailError.notConfigured }

        let server = IMAPServer(host: config.imapHost, port: config.imapPort)
        try await server.connect()
        try await server.login(username: config.username, password: config.password)
        defer { Task { try? await server.logout() } }

        let mailboxes = try await server.listMailboxes()
        return mailboxes.map { $0.name }
    }

    // MARK: - Get Recent Emails

    public func getRecentEmails(folder: String = "INBOX", count: Int = 10) async throws -> [EmailSummary] {
        guard let config else { throw MailError.notConfigured }

        let server = IMAPServer(host: config.imapHost, port: config.imapPort)
        try await server.connect()
        try await server.login(username: config.username, password: config.password)
        defer { Task { try? await server.logout() } }

        let mailboxInfo = try await server.selectMailbox(folder)

        guard let messageSet = mailboxInfo.latest(count) else {
            return []
        }

        var results: [EmailSummary] = []
        for try await msg in server.fetchMessages(using: messageSet) {
            // UID is from NIOIMAPCore, cast to Int via description
            let uidValue = msg.uid.map { Int("\($0)") ?? 0 } ?? 0
            results.append(EmailSummary(
                uid: uidValue,
                from: msg.from?.description ?? "",
                subject: msg.subject ?? "(no subject)",
                date: msg.date?.description ?? "",
                folder: folder
            ))
        }
        return results
    }

    // MARK: - Search Emails

    public func searchEmails(query: String, folder: String = "INBOX", limit: Int = 10) async throws -> [EmailSummary] {
        // Use getRecentEmails and filter client-side (SwiftMail search API may vary)
        let recent = try await getRecentEmails(folder: folder, count: 50)
        let lower = query.lowercased()
        return Array(recent.filter {
            $0.subject.lowercased().contains(lower) ||
            $0.from.lowercased().contains(lower)
        }.prefix(limit))
    }

    // MARK: - Read Email

    public func readEmail(uid: Int, folder: String = "INBOX") async throws -> EmailContent {
        guard let config else { throw MailError.notConfigured }

        let server = IMAPServer(host: config.imapHost, port: config.imapPort)
        try await server.connect()
        try await server.login(username: config.username, password: config.password)
        defer { Task { try? await server.logout() } }

        let _ = try await server.selectMailbox(folder)

        // Fetch recent messages and find by UID
        let recent = try await getRecentEmails(folder: folder, count: 50)
        guard let match = recent.first(where: { $0.uid == uid }) else {
            throw MailError.operationFailed("Email with UID \(uid) not found")
        }

        return EmailContent(
            uid: uid,
            from: match.from,
            to: "",
            subject: match.subject,
            date: match.date,
            body: "(Full body fetch requires message set — showing summary)",
            folder: folder
        )
    }

    // MARK: - Send Email

    public func sendEmail(to: String, subject: String, body: String) async throws {
        guard let config else { throw MailError.notConfigured }

        let server = SMTPServer(host: config.smtpHost, port: config.smtpPort)
        try await server.connect()
        try await server.login(username: config.username, password: config.password)

        let sender = EmailAddress(name: config.name, address: config.email)
        let recipient = EmailAddress(name: nil, address: to)
        let email = Email(
            sender: sender,
            recipients: [recipient],
            subject: subject,
            textBody: body
        )

        try await server.sendEmail(email)
        try await server.disconnect()
    }
}

// MARK: - Data Models

public struct EmailSummary: Codable, Sendable {
    public let uid: Int
    public let from: String
    public let subject: String
    public let date: String
    public let folder: String
}

public struct EmailContent: Codable, Sendable {
    public let uid: Int
    public let from: String
    public let to: String
    public let subject: String
    public let date: String
    public let body: String
    public let folder: String
}

// MARK: - Error

public enum MailError: LocalizedError {
    case notConfigured
    case connectionFailed(String)
    case authFailed
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Mail account not configured. Add an account in Settings."
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authFailed: return "Authentication failed. Check username/password."
        case .operationFailed(let msg): return "Mail operation failed: \(msg)"
        }
    }
}
