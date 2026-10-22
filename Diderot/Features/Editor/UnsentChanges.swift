import Foundation
import DocmostKit

/// Changes a page's engine had made that the server hadn't confirmed when the page closed or the app went to the
/// background (`CacheKey.unsentChanges`), and the document they make, shown offline (`CacheKey.unsentDocument`). Per
/// server and user, outside the offline cache: clearing or pruning that, iOS purging caches, signing out and another
/// user's sign-in keep them; removing the server from the app deletes them. Not in backups, like the cache.
enum UnsentChanges {
    private static let root = URL.applicationSupportDirectory.appending(path: "unsent", directoryHint: .isDirectory)

    static func store(server: URL, userId: String) -> DiskCache {
        excludeFromBackup()
        return DiskCache(scope: userId, baseDirectory: directory(of: server))
    }

    /// All users' changes for the server.
    static func removeAll(server: URL) {
        try? FileManager.default.removeItem(at: directory(of: server))
    }

    private static func directory(of server: URL) -> URL {
        DiskCache(scope: server.absoluteString, baseDirectory: root).directory
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
