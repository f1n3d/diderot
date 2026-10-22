import Foundation

/// Stored sign-in: server plus access token. Kept encrypted in the keychain.
public struct StoredSession: Codable, Sendable, Hashable, Identifiable {
    public var serverURL: URL
    public var token: String
    public var email: String?
    public var workspaceName: String?

    public init(serverURL: URL, token: String, email: String? = nil, workspaceName: String? = nil) {
        self.serverURL = serverURL
        self.token = token
        self.email = email
        self.workspaceName = workspaceName
    }

    public var id: String { StoredAccounts.key(for: serverURL) }
    public var claims: JWTClaims? { JWTClaims(token: token) }
    public var host: String { serverURL.host() ?? serverURL.absoluteString }
    public var displayName: String { workspaceName ?? host }
}

/// All stored sign-ins (one per server) and the currently selected server.
public struct StoredAccounts: Codable, Sendable, Hashable {
    public var sessions: [StoredSession]
    public var currentServerURL: URL?

    public init(sessions: [StoredSession] = [], currentServerURL: URL? = nil) {
        self.sessions = sessions
        self.currentServerURL = currentServerURL
    }

    /// Comparison key for server URLs: the whole URL lowercased, without trailing slashes.
    public static func key(for url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    public var current: StoredSession? {
        currentServerURL.flatMap { session(for: $0) }
    }

    public func session(for url: URL) -> StoredSession? {
        let key = Self.key(for: url)
        return sessions.first { Self.key(for: $0.serverURL) == key }
    }

    /// Adds the sign-in or replaces the one for the same server, and makes it current.
    public mutating func upsert(_ session: StoredSession) {
        let key = Self.key(for: session.serverURL)
        if let index = sessions.firstIndex(where: { Self.key(for: $0.serverURL) == key }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        currentServerURL = session.serverURL
    }

    /// Removes the server; if it was current, none is selected afterwards.
    public mutating func remove(serverURL: URL) {
        let key = Self.key(for: serverURL)
        sessions.removeAll { Self.key(for: $0.serverURL) == key }
        if currentServerURL.map(Self.key(for:)) == key {
            currentServerURL = nil
        }
    }

    /// Selects a stored server; `false` if it doesn't exist.
    @discardableResult
    public mutating func select(serverURL: URL) -> Bool {
        guard let session = session(for: serverURL) else { return false }
        currentServerURL = session.serverURL
        return true
    }
}

/// Secret storage behind `SessionStore`: the keychain in production, in-memory in tests.
public protocol SecretStore: Sendable {
    func save(_ data: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
}

extension KeychainStore: SecretStore {}

/// Manages stored sign-ins; the legacy single entry (`session`) moves into the list (`accounts`) on first load.
public struct SessionStore: Sendable {
    private static let legacyAccount = "session"
    private static let accountsKey = "accounts"
    private let store: any SecretStore

    public init(keychain: any SecretStore = KeychainStore()) {
        self.store = keychain
    }

    /// The current sign-in (for restoring it at launch).
    public func load() throws -> StoredSession? {
        try loadAccounts().current
    }

    public func loadAccounts() throws -> StoredAccounts {
        if let data = try store.load(account: Self.accountsKey) {
            return try JSONDecoder().decode(StoredAccounts.self, from: data)
        }
        if let data = try store.load(account: Self.legacyAccount) {
            var accounts = StoredAccounts()
            accounts.upsert(try JSONDecoder().decode(StoredSession.self, from: data))
            try saveAccounts(accounts)
            try store.delete(account: Self.legacyAccount)
            return accounts
        }
        return StoredAccounts()
    }

    private func saveAccounts(_ accounts: StoredAccounts) throws {
        try store.save(JSONEncoder().encode(accounts), account: Self.accountsKey)
    }

    /// Saves a sign-in and makes it current; other servers are kept.
    public func save(_ session: StoredSession) throws {
        var accounts = try loadAccounts()
        accounts.upsert(session)
        try saveAccounts(accounts)
    }

    /// Removes the current sign-in (sign-out); other servers are kept.
    public func clear() throws {
        var accounts = try loadAccounts()
        guard let current = accounts.currentServerURL else { return }
        accounts.remove(serverURL: current)
        try saveAccounts(accounts)
    }

    public func remove(serverURL: URL) throws {
        var accounts = try loadAccounts()
        accounts.remove(serverURL: serverURL)
        try saveAccounts(accounts)
    }

    /// Makes a stored server current and returns its sign-in.
    public func select(serverURL: URL) throws -> StoredSession? {
        var accounts = try loadAccounts()
        guard accounts.select(serverURL: serverURL) else { return nil }
        try saveAccounts(accounts)
        return accounts.current
    }
}
