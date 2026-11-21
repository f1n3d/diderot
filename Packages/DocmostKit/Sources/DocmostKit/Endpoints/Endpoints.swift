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

        public struct UserIdBody: Encodable, Sendable {
            public let userId: String
        }

        /// A person's profile (Docmost 0.98; older servers answer 404). The server answers 400 for an id that is no
        /// UUID, 404 for one it doesn't know.
        public static func info(userId: String) -> Endpoint<UserProfile> {
            .post("users/info", body: UserIdBody(userId: userId))
        }

        public struct ProfileListBody: Encodable, Sendable {
            public let userId: String
            public var limit: Int?
            public var cursor: String?
        }

        /// The active spaces both the user and this person are members of (Docmost 0.98), by name; `limit` is at most
        /// 100. The web asks for 10 at a time.
        public static func spaces(userId: String, cursor: String? = nil, limit: Int = 10) -> Endpoint<Paginated<UserProfileSpace>> {
            .post("users/spaces", body: ProfileListBody(userId: userId, limit: limit, cursor: cursor))
        }

        /// The pages this person created or edited last, newest first (Docmost 0.98); 10 at a time, as the web asks.
        public static func recentPages(userId: String, cursor: String? = nil, limit: Int = 10) -> Endpoint<Paginated<UserRecentPage>> {
            .post("users/recent-pages", body: ProfileListBody(userId: userId, limit: limit, cursor: cursor))
        }
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
