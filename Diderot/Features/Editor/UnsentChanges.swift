import Foundation
import Synchronization
import DocmostKit

/// Changes a page's engine had made that the server hadn't confirmed when the page closed or the app went to the
/// background (`CacheKey.unsentChanges`), and the document they make, shown offline (`CacheKey.unsentDocument`); page
/// titles (`UnsentTitle`) and database fields (`UnsentCell`) whose save didn't reach the server. Per
/// server and user, outside the offline cache: clearing or pruning that, iOS purging caches, signing out and another
/// user's sign-in keep them; removing the server from the app deletes them. Not in backups, like the cache.
enum UnsentChanges {
    private static let root = URL.applicationSupportDirectory.appending(path: "unsent", directoryHint: .isDirectory)
    private static let stores = Mutex<[URL: UnsentStore]>([:])

    /// The same store for every caller of a server and user, so its `update`s come one after another (two windows, or a
    /// title kept while the kept ones go out).
    static func store(server: URL, userId: String) -> UnsentStore {
        excludeFromBackup()
        let directory = directory(of: server).appending(path: "docmost-cache/\(UnsentStore.name(for: userId))", directoryHint: .isDirectory)
        return stores.withLock { stores in
            if let existing = stores[directory] { return existing }
            let store = UnsentStore(directory: directory)
            stores[directory] = store
            return store
        }
    }

    /// Whether any user's changes or titles still wait for the server (asked before removing it).
    static func hasEntries(server: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: directory(of: server), includingPropertiesForKeys: nil) else { return false }
        return files.contains { item in
            guard let url = item as? URL, ["bin", "json"].contains(url.pathExtension) else { return false }
            // The lists of titles and fields stay behind as "{}" once they are all sent.
            return (try? JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url)))?.isEmpty != true
        }
    }

    /// Errors after which a kept change can never be saved (page or entry deleted, access gone, value refused): it isn't
    /// kept.
    static func isFinal(_ error: Error) -> Bool {
        guard let error = error as? APIError else { return false }
        if error.isGone { return true }
        if case .validation = error { return true }
        return false
    }

    /// All users' changes for the server.
    static func removeAll(server: URL) {
        try? FileManager.default.removeItem(at: directory(of: server))
    }

    /// The server's folder: `unsent/docmost-cache/<server>`, and in it `docmost-cache/<user>`. The offline cache's
    /// layout when these first went there, fixed since (`UnsentStore.name(for:)`): every user's are found by it. The
    /// server's URL as it was added (`StoredAccounts.upsert` keeps that).
    static func directory(of server: URL) -> URL {
        root.appending(path: "docmost-cache/\(UnsentStore.name(for: server.absoluteString))", directoryHint: .isDirectory)
    }

    private static func excludeFromBackup() {
        var url = root
        guard (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) != true else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// A page title the server didn't get (offline or unreachable when saving), kept in `UnsentChanges`' store under
/// `CacheKey.unsentTitles` until `AppSession.sendUnsentTitles` gets it through. The last save wins, as on the web.
nonisolated struct UnsentTitle: Codable, Sendable {
    var title: String
    var spaceId: String?
}

/// A database field's input the server didn't get, kept in `UnsentChanges`' store under `CacheKey.unsentCells` until
/// `AppSession.sendUnsentCells` gets it through; meanwhile its input shows the typed text. The last save wins.
nonisolated struct UnsentCell: Codable, Sendable, Equatable {
    var basePageId: String
    var rowId: String
    var propertyId: String
    /// The value to save; `.null` clears the cell.
    var value: JSONValue
    /// The text as typed.
    var typed: String
    /// The property's name, for the message when the server refuses it for good.
    var propertyName: String

    /// Its key in the kept list.
    var key: String { Self.key(basePageId: basePageId, rowId: rowId, propertyId: propertyId) }

    static func key(basePageId: String, rowId: String, propertyId: String) -> String { "\(basePageId)/\(rowId)/\(propertyId)" }
}
