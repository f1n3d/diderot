import Foundation

extension Endpoints {
    /// Links to other services (Docmost 0.97): the workspace's integrations, previews of links, connecting one's account.
    /// Installing integrations stays in the web's workspace settings.
    public enum Integrations {
        /// The integrations installed in the workspace.
        public static var installed: Endpoint<[Integration]> { .post("integrations") }

        public struct UnfurlBody: Encodable, Sendable {
            public let url: String
        }

        /// What the server can tell about a link: a preview, a request to connect one's account first, or nothing
        /// (no installed integration previews it). The server limits this to 120 calls a minute per user.
        public static func unfurl(_ url: String) -> Endpoint<UnfurlResponse> {
            .post("integrations/unfurl", body: UnfurlBody(url: url))
        }

        public struct AuthorizeBody: Encodable, Sendable {
            public let integrationId: String
            public let returnPath: String?
        }

        /// The service's sign-in page that connects the user's account to an installed integration; afterwards the
        /// browser comes back to `returnPath` on the server.
        public static func authorize(integrationId: String, returnPath: String?) -> Endpoint<IntegrationAuthorization> {
            .post("integrations/oauth/authorize", body: AuthorizeBody(integrationId: integrationId, returnPath: returnPath))
        }
    }
}

/// An integration installed in the workspace.
public struct Integration: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    /// The service, e.g. `github` (`IntegrationLinks.Provider`).
    public let type: String
    /// Hosts it previews besides the service's own, e.g. a self-hosted GitLab; `*.example.com` covers subdomains.
    public let unfurlHosts: [String]?

    public init(id: String, type: String, unfurlHosts: [String]? = nil) {
        self.id = id
        self.type = type
        self.unfurlHosts = unfurlHosts
    }
}

public struct UnfurlResponse: Codable, Sendable, Hashable {
    public let data: LinkPreview?
}

/// The server's answer about a link (also kept on disk, so it encodes as the server sent it).
public enum LinkPreview: Codable, Sendable, Hashable {
    case preview(Preview)
    case needsConnection(ConnectionNeeded)

    /// A link's title and state. Avatars and service icons the server names are left out: loading them would contact
    /// the service from the app.
    public struct Preview: Codable, Sendable, Hashable {
        public let title: String
        public let description: String?
        public let url: String
        public let provider: String
        /// E.g. "Open", "Merged", "In Progress".
        public let status: String?
        /// The service's color for the status: a name ("green") or hex.
        public let statusColor: String?
        public let author: String?
        /// Per kind of link, e.g. `updatedAt`, `replyCount`.
        public let metadata: [String: JSONValue]?
    }

    /// The link's service is installed but this user hasn't connected an account yet.
    public struct ConnectionNeeded: Codable, Sendable, Hashable {
        public let integrationId: String
        public let integrationType: String
        public let integrationName: String
        public let title: String
        public let description: String?
    }

    private enum Keys: String, CodingKey {
        case needsConnection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .needsConnection) == true {
            self = .needsConnection(try ConnectionNeeded(from: decoder))
        } else {
            self = .preview(try Preview(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .preview(let preview):
            try preview.encode(to: encoder)
        case .needsConnection(let needed):
            try needed.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(true, forKey: .needsConnection)
        }
    }
}

public struct IntegrationAuthorization: Decodable, Sendable, Hashable {
    public let authorizationUrl: URL
}
