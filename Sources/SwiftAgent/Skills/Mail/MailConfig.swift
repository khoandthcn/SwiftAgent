import Foundation

// MARK: - Mail Account Configuration

public struct MailAccountConfig: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String           // display name (e.g., "Work Email")
    public var email: String          // user@example.com

    // IMAP settings (receiving)
    public var imapHost: String       // e.g., "imap.gmail.com"
    public var imapPort: Int          // typically 993 (SSL) or 143
    public var imapUseSSL: Bool

    // SMTP settings (sending)
    public var smtpHost: String       // e.g., "smtp.gmail.com"
    public var smtpPort: Int          // typically 465 (SSL) or 587 (STARTTLS)
    public var smtpUseSSL: Bool

    // Auth
    public var username: String       // often same as email
    public var password: String       // app-specific password recommended

    public init(
        name: String = "",
        email: String = "",
        imapHost: String = "",
        imapPort: Int = 993,
        imapUseSSL: Bool = true,
        smtpHost: String = "",
        smtpPort: Int = 465,
        smtpUseSSL: Bool = true,
        username: String = "",
        password: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.email = email
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUseSSL = imapUseSSL
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUseSSL = smtpUseSSL
        self.username = username
        self.password = password
    }

    // MARK: - Validation

    public var isValid: Bool {
        !email.isEmpty && !imapHost.isEmpty && !password.isEmpty
    }
}

// MARK: - Mail Account Store

public final class MailAccountStore: @unchecked Sendable {
    public static let shared = MailAccountStore()

    private let fileURL: URL
    private var accounts: [MailAccountConfig] = []

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwiftAgent")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("mail_accounts.json")
        load()
    }

    public func getAccounts() -> [MailAccountConfig] { accounts }

    public func getAccount(byID id: UUID) -> MailAccountConfig? {
        accounts.first { $0.id == id }
    }

    public func getDefaultAccount() -> MailAccountConfig? {
        accounts.first
    }

    public func addAccount(_ account: MailAccountConfig) {
        accounts.append(account)
        save()
    }

    public func updateAccount(_ account: MailAccountConfig) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
            save()
        }
    }

    public func removeAccount(id: UUID) {
        accounts.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return }
        accounts = (try? JSONDecoder().decode([MailAccountConfig].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: fileURL)
    }
}
