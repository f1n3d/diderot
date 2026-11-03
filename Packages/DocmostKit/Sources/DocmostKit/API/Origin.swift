import Foundation

/// Where a URL is served from, as browsers compare it: scheme and host in lower case, and the port, the scheme's default
/// if none is given (`https://Wiki.example.com` and `https://wiki.example.com:443` are one origin).
public struct Origin: Hashable, Sendable {
    public let scheme: String?
    public let host: String?
    public let port: Int?

    public init(_ url: URL) {
        scheme = url.scheme?.lowercased()
        host = url.host()?.lowercased()
        port = url.port ?? scheme.flatMap { ["http": 80, "https": 443][$0] }
    }
}

/// A server, as the app tells servers apart: its origin, so `https://Wiki.example.com:443/` and
/// `https://wiki.example.com` are one server (Docmost runs at the root of its origin). What the app keeps for a server
/// is named by the URL it was added with (`StoredAccounts.key(for:)`, the offline cache, unsent changes); adding the
/// server again in another spelling keeps that one (`StoredAccounts.upsert`).
public struct ServerKey: Hashable, Sendable {
    private let origin: Origin

    public init(_ url: URL) {
        origin = Origin(url)
    }
}
