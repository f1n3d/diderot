import Foundation
import DocmostKit

/// The server in use, before and after sign-in.
struct ServerInfo: Hashable, Sendable {
    var url: URL
    var workspace: PublicWorkspace?

    var displayName: String { workspace?.name ?? url.host() ?? url.absoluteString }
}

/// Signed-in session.
struct ReadySession: Sendable {
    let server: ServerInfo
    let client: APIClient
    let imageLoader: ImageLoader
    /// Offline cache for this server's lists, pages and images.
    let cache: DiskCache
    /// This user's changes the server hasn't confirmed yet (`UnsentChanges`).
    let unsentChanges: UnsentStore
    /// Access token, e.g. for WebViews that need the `authToken` cookie.
    let token: String
    var currentUser: CurrentUser
    var entitlements: Entitlements
    /// Docmost version, else the last one this server told; nil if never known (Docmost Cloud, the server's GitHub check
    /// failing or taking too long since the first sign-in).
    var serverVersion: String?
    var tokenClaims: JWTClaims? { JWTClaims(token: token) }
    /// Restored from the cache without reaching the server.
    var restoredOffline = false

    /// The server's version if it is newer than the bundled editor's (Docmost 0.97, `Engine/`), which could damage
    /// content it doesn't know: pages there open read-only. An unknown version counts as supported.
    var newerServerVersion: String? { Self.isNewerThanEditor(serverVersion) ? serverVersion : nil }

    /// Docmost 0.97 or newer: tabs, integration links and sorted sub-pages can be added. An unknown version doesn't
    /// count: on an older server they would get lost.
    var hasDocmost097Features: Bool { Self.supportsDocmost097(serverVersion) }

    static func supportsDocmost097(_ version: String?) -> Bool {
        majorMinor(version).map { $0 >= (0, 97) } ?? false
    }

    static func isNewerThanEditor(_ version: String?) -> Bool {
        majorMinor(version).map { $0 > (0, 97) } ?? false
    }

    private static func majorMinor(_ version: String?) -> (Int, Int)? {
        let parts = version?.trimmingPrefix("v").split(separator: ".").prefix(2).map { Int($0.prefix(while: \.isNumber)) }
        guard let parts, parts.count == 2, let major = parts[0], let minor = parts[1] else { return nil }
        return (major, minor)
    }
}
