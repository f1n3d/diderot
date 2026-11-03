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
    /// logos and avatars) and the server's web editor data; with `uploads`, also the files staged for upload.
    var removeLocalData: (URL, _ uploads: Bool) async -> Void
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
        removeLocalData = { url, uploads in
            TempFile.removeAll(server: url, uploads: uploads)
            // Holds only member avatars, of every server: it can't be cleared for one.
            URLCache.shared.removeAllCachedResponses()
            await WebEditorStores.remove(for: url)
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
