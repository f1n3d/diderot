import Foundation
import Network
import DocmostKit

/// What a session reaches outside itself: the servers' API, their offline caches, the local data those don't cover,
/// and the network. `AppSession` gets the app's; a test changes a part to see what the session does with it (no
/// network at the start, the network changing, what signing out removes).
struct SessionEnvironment {
    /// A client for the server, with a session's token or none.
    var makeClient: (URL, String?) -> APIClient
    /// The server's offline cache.
    var makeCache: (URL) -> DiskCache
    /// The store for what a user's edits on the server haven't confirmed yet (`UnsentChanges`).
    var makeUnsentStore: (URL, _ userId: String) -> UnsentStore
    /// Removes what the server's offline cache doesn't cover: downloads, the system URL cache (files of older builds,
    /// logos and avatars) and the web editor's cache, and as `removal` says, the files staged for upload and the web
    /// editor's own storage.
    var removeLocalData: (URL, _ removal: LocalDataRemoval) async -> Void
    /// Whether the device has no network now (flight mode).
    var hasNoNetwork: () async -> Bool
    /// Returns true once the network changes to one with a connection (a VPN coming on, another Wi-Fi), not for the
    /// network as it is now; false if cancelled first.
    var networkReturns: () async -> Bool

    /// The app's. Tests answer the API requests with `protocolClasses`.
    init(protocolClasses: [AnyClass]? = nil) {
        makeClient = { url, token in
            // A fresh configuration per client: clients made from one share its in-memory URL cache.
            let configuration = URLSessionConfiguration.ephemeral
            if let protocolClasses { configuration.protocolClasses = protocolClasses }
            return APIClient(baseURL: url, token: token, userAgent: AppSession.userAgent, configuration: configuration,
                             logger: AppLog.apiRequestLogger)
        }
        makeCache = { DiskCache(scope: $0.absoluteString) }
        makeUnsentStore = { UnsentChanges.store(server: $0, userId: $1) }
        removeLocalData = { url, removal in
            TempFile.removeAll(server: url, uploads: removal.uploads)
            // Holds only member avatars, of every server: it can't be cleared for one.
            URLCache.shared.removeAllCachedResponses()
            if removal.webStorage {
                await WebEditorStores.remove(for: url)
            } else {
                await WebEditorStores.removeCache(for: url)
            }
        }
        hasNoNetwork = {
            // A monitor reports the current path right after starting.
            for await path in NWPathMonitor() { return path.status != .satisfied }
            return false
        }
        networkReturns = {
            var paths = NWPathMonitor().makeAsyncIterator()
            _ = await paths.next()
            while let path = await paths.next(), !Task.isCancelled {
                if path.status == .satisfied { return true }
            }
            return false
        }
    }
}

/// What `SessionEnvironment.removeLocalData` removes for a server besides what it always does.
struct LocalDataRemoval: Equatable, Sendable {
    /// The files staged for upload, which a running upload reads.
    var uploads = true
    /// The web editor's own storage: its copies of pages, with the edits the server doesn't have yet, which Docmost's
    /// web client keeps there until it has sent them. Without it, only the web editor's cache goes.
    var webStorage = true

    /// Signing out, removing the server, another user signing in: everything.
    static let all = LocalDataRemoval()
    /// "Clear Saved Content": copies and files, not the edits the server doesn't have yet.
    static let savedContent = LocalDataRemoval(webStorage: false)
}
