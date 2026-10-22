import Foundation

extension Endpoints {
    public enum Sessions {
        public static var list: Endpoint<UserSessionList> { .post("sessions") }

        public struct RevokeBody: Encodable, Sendable {
            public let sessionId: String
        }

        /// The current session can't be revoked here (400); use `auth/logout` for that.
        public static func revoke(sessionId: String) -> Endpoint<NoContent> {
            .post("sessions/revoke", body: RevokeBody(sessionId: sessionId))
        }

        /// Revokes all other sessions.
        public static var revokeAll: Endpoint<NoContent> { .post("sessions/revoke-all") }
    }

    public enum MFA {
        public struct VerifyBody: Encodable, Sendable {
            public let code: String
        }

        /// Enterprise: second sign-in step. The transfer token from the sign-in is sent as the `mfaToken` cookie;
        /// on success `authToken` comes back via Set-Cookie (see `LoginFlow.verifyMFA`).
        public static func verify(code: String, mfaToken: String) -> Endpoint<NoContent> {
            Endpoint(path: "mfa/verify", body: VerifyBody(code: code), headers: ["Cookie": "mfaToken=\(mfaToken)"], requiresAuth: false)
        }
    }

    public enum SSO {
        public struct LDAPBody: Encodable, Sendable {
            public let username: String
            public let password: String
        }

        /// LDAP sign-in behaves like `auth/login` (`authToken` cookie).
        public static func ldapLogin(providerId: String, username: String, password: String) -> Endpoint<NoContent> {
            .post("sso/ldap/\(providerId)/login", body: LDAPBody(username: username, password: password), requiresAuth: false)
        }

        /// Browser sign-in URL for OIDC/SAML/Google; its redirects end in the web client with the `authToken` cookie.
        public static func browserLoginURL(server: URL, provider: AuthProvider, workspaceId: String?) -> URL {
            switch provider.type {
            case "google":
                var components = URLComponents(url: server.appending(path: "api/sso/google/login"), resolvingAgainstBaseURL: false)!
                if let workspaceId {
                    components.queryItems = [URLQueryItem(name: "workspaceId", value: workspaceId)]
                }
                return components.url!
            default:
                return server.appending(path: "api/sso/\(provider.type)/\(provider.id)/login")
            }
        }
    }
}
