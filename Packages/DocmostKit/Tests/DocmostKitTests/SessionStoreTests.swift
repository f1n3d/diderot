import Foundation
import Synchronization
import Testing
@testable import DocmostKit

/// Multiple stored sign-ins: one entry per server, selection, removal, migration of the legacy single entry.
struct SessionStoreTests {
    private let wiki = URL(string: "https://wiki.example.com")!
    private let docs = URL(string: "https://docs.example.org")!

    private func session(_ url: URL, token: String = "t", workspace: String? = nil) -> StoredSession {
        StoredSession(serverURL: url, token: token, email: "me@example.com", workspaceName: workspace)
    }

    @Test func upsertReplacesSameServerAndSelectsIt() {
        var accounts = StoredAccounts()
        accounts.upsert(session(wiki, token: "old"))
        accounts.upsert(session(docs))
        #expect(accounts.sessions.count == 2)
        #expect(accounts.current?.serverURL == docs)
        accounts.upsert(session(URL(string: "https://WIKI.example.com/")!, token: "new"))
        #expect(accounts.sessions.count == 2)
        #expect(accounts.current?.token == "new")
        #expect(accounts.sessions.map(\.serverURL) == [URL(string: "https://WIKI.example.com/")!, docs])
    }

    @Test func removeClearsSelectionOnlyForCurrent() {
        var accounts = StoredAccounts()
        accounts.upsert(session(wiki))
        accounts.upsert(session(docs))
        accounts.remove(serverURL: wiki)
        #expect(accounts.current?.serverURL == docs)
        accounts.remove(serverURL: docs)
        #expect(accounts.current == nil)
        #expect(accounts.sessions.isEmpty)
        let selected = accounts.select(serverURL: wiki)
        #expect(!selected)
    }

    @Test func storeSavesSelectsAndClearsCurrentOnly() throws {
        let store = SessionStore(keychain: MemorySecretStore())
        try store.save(session(wiki, workspace: "Wiki"))
        try store.save(session(docs, workspace: "Docs"))
        #expect(try store.load()?.workspaceName == "Docs")
        #expect(try store.select(serverURL: wiki)?.workspaceName == "Wiki")
        #expect(try store.load()?.serverURL == wiki)
        try store.clear()
        #expect(try store.load() == nil)
        #expect(try store.loadAccounts().sessions.map(\.serverURL) == [docs])
        try store.remove(serverURL: docs)
        #expect(try store.loadAccounts().sessions.isEmpty)
    }

    @Test func migratesLegacySingleSession() throws {
        let secrets = MemorySecretStore()
        try secrets.save(JSONEncoder().encode(session(wiki, workspace: "Wiki")), account: "session")
        let store = SessionStore(keychain: secrets)
        #expect(try store.load()?.workspaceName == "Wiki")
        #expect(try secrets.load(account: "session") == nil)
        #expect(try secrets.load(account: "accounts") != nil)
    }

    @Test func displayNameFallsBackToHost() {
        #expect(session(wiki).displayName == "wiki.example.com")
        #expect(session(wiki, workspace: "Wiki").displayName == "Wiki")
    }
}

/// In-memory stand-in for the keychain.
private final class MemorySecretStore: SecretStore {
    private let storage = Mutex<[String: Data]>([:])

    func save(_ data: Data, account: String) throws {
        storage.withLock { $0[account] = data }
    }

    func load(account: String) throws -> Data? {
        storage.withLock { $0[account] }
    }

    func delete(account: String) throws {
        storage.withLock { _ = $0.removeValue(forKey: account) }
    }
}
