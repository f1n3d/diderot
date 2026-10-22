import Foundation

public struct Workspace: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let logo: String?
    public let memberCount: Int?
}

/// Response of `POST /api/workspace/public`; available without sign-in.
public struct PublicWorkspace: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let logo: String?
    public let enforceSso: Bool?
    public let authProviders: [AuthProvider]?

    public var providers: [AuthProvider] { authProviders ?? [] }
    public var requiresSso: Bool { enforceSso ?? false }
}

/// SSO provider (Enterprise edition). `type` is `oidc`, `saml`, `google` or `ldap`.
public struct AuthProvider: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let type: String

    public var isLDAP: Bool { type == "ldap" }
}

/// Response of `POST /api/version`. Without data when the server's own GitHub release check fails (e.g. rate limited).
public struct ServerVersion: Decodable, Sendable, Hashable {
    public let currentVersion: String?
}

/// Response of `POST /api/workspace/entitlements`. Community edition: `{cloud: false, tier: "free", features: []}`.
public struct Entitlements: Codable, Sendable, Hashable {
    public let tier: String
    public let features: [String]

    public static let community = Entitlements(tier: "free", features: [])

    public func has(_ feature: String) -> Bool {
        features.contains(feature)
    }
}
