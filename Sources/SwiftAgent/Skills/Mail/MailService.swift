import Foundation
import SwiftMail

// MARK: - Mail Service
//
// Full IMAP/SMTP service using SwiftMail.
// Provides rich search, read, reply, forward, flag, move operations.

public actor MailService {

    private var config: MailAccountConfig?

    public init() {}

    public func configure(_ account: MailAccountConfig) {
        self.config = account
    }

    public var isConfigured: Bool { config != nil }

    // MARK: - Connect helper

    private func connectIMAP() async throws -> IMAPServer {
        guard let config else { throw MailError.notConfigured }
        let server = IMAPServer(host: config.imapHost, port: config.imapPort)
        try await server.connect()
        try await server.login(username: config.username, password: config.password)
        return server
    }

    // MARK: - List Folders

    public func listFolders() async throws -> [String] {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }
        let mailboxes = try await server.listMailboxes()
        return mailboxes.map { $0.name }
    }

    // MARK: - Get Recent Emails

    public func getRecentEmails(folder: String = "INBOX", count: Int = 10) async throws -> [MailMessage] {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }

        let selection = try await server.selectMailbox(folder)
        guard let messageSet = selection.latest(count) else { return [] }

        var results: [MailMessage] = []
        for try await info in server.fetchMessageInfos(using: messageSet) {
            results.append(MailMessage(from: info, folder: folder))
        }
        return results.reversed() // newest first
    }

    // MARK: - Search Emails (rich IMAP search)

    public func searchEmails(
        from: String? = nil,
        subject: String? = nil,
        body: String? = nil,
        keyword: String? = nil,
        unreadOnly: Bool = false,
        since: Date? = nil,
        folder: String = "INBOX",
        limit: Int = 10
    ) async throws -> [MailMessage] {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }

        let _ = try await server.selectMailbox(folder)

        // Build search criteria
        var criteria: [SearchCriteria] = []
        if let from { criteria.append(.from(from)) }
        if let subject { criteria.append(.subject(subject)) }
        if let body { criteria.append(.body(body)) }
        if let keyword {
            // keyword: search in subject OR from OR body
            criteria.append(.or(.subject(keyword), .or(.from(keyword), .body(keyword))))
        }
        if unreadOnly { criteria.append(.unseen) }
        if let since { criteria.append(.since(since)) }
        if criteria.isEmpty { criteria.append(.all) }

        let uidSet: UIDSet = try await server.search(criteria: criteria)
        guard !uidSet.isEmpty else { return [] }

        var results: [MailMessage] = []
        for try await info in server.fetchMessageInfos(using: uidSet) {
            results.append(MailMessage(from: info, folder: folder))
            if results.count >= limit { break }
        }
        return results.reversed()
    }

    // MARK: - Read Email (full content)

    public func readEmail(uid: UID, folder: String = "INBOX") async throws -> MailMessageFull {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }

        let _ = try await server.selectMailbox(folder)

        guard let info = try await server.fetchMessageInfo(for: uid) else {
            throw MailError.operationFailed("Email not found")
        }

        // Fetch full message content
        let message = try await server.fetchMessage(from: info)

        let bodyText = message.textBody ?? message.htmlBody?.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Mark as seen
        let uidSet = UIDSet(uid)
        try? await server.store(flags: [.seen], on: uidSet, operation: .add)

        return MailMessageFull(
            info: MailMessage(from: info, folder: folder),
            body: String(bodyText.prefix(3000)),
            hasAttachments: info.parts.contains { $0.disposition == "attachment" }
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

        var email = Email(
            sender: sender,
            recipients: [recipient],
            subject: subject,
            textBody: body
        )


        try await server.sendEmail(email)
        try await server.disconnect()
    }

    // MARK: - Move to Folder

    public func moveEmail(uid: UID, toFolder: String, fromFolder: String = "INBOX") async throws {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }
        let _ = try await server.selectMailbox(fromFolder)
        try await server.move(message: uid, to: toFolder)
    }

    // MARK: - Flag Management

    public func markAsRead(uid: UID, folder: String = "INBOX") async throws {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }
        let _ = try await server.selectMailbox(folder)
        try await server.store(flags: [.seen], on: UIDSet(uid), operation: .add)
    }

    public func markAsUnread(uid: UID, folder: String = "INBOX") async throws {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }
        let _ = try await server.selectMailbox(folder)
        try await server.store(flags: [.seen], on: UIDSet(uid), operation: .remove)
    }

    public func flagEmail(uid: UID, folder: String = "INBOX") async throws {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }
        let _ = try await server.selectMailbox(folder)
        try await server.store(flags: [.flagged], on: UIDSet(uid), operation: .add)
    }

    // MARK: - Trash

    public func trashEmail(uid: UID, folder: String = "INBOX") async throws {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }
        let _ = try await server.selectMailbox(folder)
        try await server.moveToTrash(messages: UIDSet(uid))
    }

    // MARK: - Unread Count

    public func unreadCount(folder: String = "INBOX") async throws -> Int {
        let server = try await connectIMAP()
        defer { Task { try? await server.logout() } }
        let status = try await server.mailboxStatus(folder)
        return status.unseenCount ?? 0
    }
}

// MARK: - Data Models

public struct MailMessage: Codable, Sendable, Identifiable {
    public var id: String { "\(uid)" }
    public let uid: Int
    public let from: String
    public let to: [String]
    public let subject: String
    public let date: String
    public let dateRaw: Date?
    public let isRead: Bool
    public let isFlagged: Bool
    public let folder: String
    public let messageId: String?
    public let hasAttachments: Bool

    init(from info: MessageInfo, folder: String) {
        self.uid = info.uid.map { Int("\($0)") ?? 0 } ?? 0
        self.from = info.from ?? ""
        self.to = info.to
        self.subject = info.subject ?? "(no subject)"
        self.dateRaw = info.date
        self.date = info.date?.formatted(.dateTime.month().day().hour().minute()) ?? ""
        self.isRead = info.flags.contains(.seen)
        self.isFlagged = info.flags.contains(.flagged)
        self.folder = folder
        self.messageId = info.messageId?.description
        self.hasAttachments = info.parts.contains { $0.disposition == "attachment" }
    }
}

public struct MailMessageFull: Sendable {
    public let info: MailMessage
    public let body: String
    public let hasAttachments: Bool
}

// MARK: - Error

public enum MailError: LocalizedError {
    case notConfigured
    case connectionFailed(String)
    case authFailed
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Mail account not configured."
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authFailed: return "Authentication failed."
        case .operationFailed(let msg): return "Mail error: \(msg)"
        }
    }
}
