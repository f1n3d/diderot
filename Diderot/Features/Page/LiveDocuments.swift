import Foundation
import DocmostKit

/// The engine's last document of each editable page opened online, in memory for 90 s: the server persists `content`
/// only ~10 s after the last change, so a page reopened meanwhile shows the engine's state. It can hold edits the server
/// hasn't confirmed, so it is kept per server and user and emptied on signing out and switching servers: keyed by page
/// alone, another account on the device was shown them, read-only too.
@MainActor
enum LiveDocuments {
    /// Whose documents: a user's on a server.
    struct Owner: Hashable {
        let server: String
        let userId: String

        init(server: URL, userId: String) {
            self.server = StoredAccounts.key(for: server)
            self.userId = userId
        }

        init(_ session: ReadySession) {
            self.init(server: session.server.url, userId: session.currentUser.user.id)
        }
    }

    private struct Key: Hashable {
        let owner: Owner
        let pageId: String
    }

    private struct Entry {
        let document: PMNode
        let storedAt: Date
    }

    private static var entries: [Key: Entry] = [:]
    private static let maxAge: TimeInterval = 90

    static func store(_ document: PMNode, for pageId: String, owner: Owner) {
        entries = entries.filter { Date.now.timeIntervalSince($0.value.storedAt) < maxAge }
        entries[Key(owner: owner, pageId: pageId)] = Entry(document: document, storedAt: .now)
    }

    /// The cached document if newer than the server state; `serverClockOffset` maps the server's `updatedAt` to the
    /// device clock.
    static func document(for pageId: String, owner: Owner, newerThan updatedAt: Date?, serverClockOffset: TimeInterval) -> PMNode? {
        let key = Key(owner: owner, pageId: pageId)
        guard let entry = entries[key], Date.now.timeIntervalSince(entry.storedAt) < maxAge else {
            entries[key] = nil
            return nil
        }
        if let updatedAt, updatedAt - serverClockOffset > entry.storedAt { return nil }
        return entry.document
    }

    /// Forgets every document: the app signs out or switches servers.
    static func removeAll() {
        entries = [:]
    }
}
