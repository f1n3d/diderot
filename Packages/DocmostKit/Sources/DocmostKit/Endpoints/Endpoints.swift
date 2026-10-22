import Foundation

/// All API calls, grouped like the server controllers. Almost everything is `POST /api/<resource>/<action>`.
public enum Endpoints {
    public enum Auth {
        public struct LoginBody: Encodable, Sendable {
            public let email: String
            public let password: String
        }

        /// Success only sets the `authToken` cookie (empty body); see `LoginFlow`.
        public static func login(email: String, password: String) -> Endpoint<NoContent> {
            .post("auth/login", body: LoginBody(email: email, password: password), requiresAuth: false)
        }

        /// Revokes the session on the server.
        public static var logout: Endpoint<NoContent> { .post("auth/logout") }

        public struct CollabToken: Decodable, Sendable, Hashable {
            public let token: String
        }

        public static var collabToken: Endpoint<CollabToken> { .post("auth/collab-token") }
    }

    public enum Users {
        public static var me: Endpoint<CurrentUser> { .post("users/me") }
    }

    public enum Workspace {
        /// No sign-in required: name, logo, SSO providers.
        public static var publicInfo: Endpoint<PublicWorkspace> { .post("workspace/public", requiresAuth: false) }
        public static var entitlements: Endpoint<Entitlements> { .post("workspace/entitlements") }
    }

    public enum Version {
        /// The server asks GitHub for the latest release first, which can hang behind a firewall: 3 s at most.
        public static var info: Endpoint<ServerVersion> { .post("version", timeout: 3) }
    }
}
