import Foundation

/// Result of a password or LDAP sign-in.
public enum LoginResult: Sendable, Hashable {
    case authenticated(token: String)
    /// Enterprise MFA: sign-in completes only after `mfa/verify`.
    case mfaRequired(MFAChallenge)
}

public struct MFAChallenge: Sendable, Hashable, Decodable {
    public let userHasMfa: Bool?
    public let requiresMfaSetup: Bool?
    /// Transfer token from the `mfaToken` cookie (valid for 5 minutes); sent as a Cookie header to `mfa/verify`.
    public var mfaToken: String?

    enum CodingKeys: String, CodingKey {
        case userHasMfa, requiresMfaSetup
    }

    /// MFA must be set up in the web client first; until then the app can't complete sign-in.
    public var needsSetup: Bool { requiresMfaSetup == true && userHasMfa != true }
}

public enum LoginFlow {
    /// `POST /api/auth/login`. The token arrives only as `Set-Cookie: authToken=…`.
    public static func loginWithPassword(client: APIClient, email: String, password: String) async throws -> LoginResult {
        try await login(client: client, endpoint: Endpoints.Auth.login(email: email, password: password))
    }

    /// LDAP sign-in (Enterprise); same response shape as the password sign-in.
    public static func loginWithLDAP(client: APIClient, providerId: String, username: String, password: String) async throws -> LoginResult {
        try await login(client: client, endpoint: Endpoints.SSO.ldapLogin(providerId: providerId, username: username, password: password))
    }

    /// Second MFA step: returns the access token from the response's `authToken` cookie.
    public static func verifyMFA(client: APIClient, challenge: MFAChallenge, code: String) async throws -> String {
        guard let mfaToken = challenge.mfaToken else {
            throw APIError.unauthorized(message: String(localized: "The sign-in session expired. Please sign in again.", bundle: .main))
        }
        let (_, response) = try await client.sendRaw(Endpoints.MFA.verify(code: code.trimmingCharacters(in: .whitespaces), mfaToken: mfaToken))
        let cookies = SetCookieParser.cookies(from: response)
        guard let token = cookies["authToken"], JWTClaims(token: token)?.isAccessToken == true else {
            throw APIError.unexpectedPayload
        }
        return token
    }

    private static func login(client: APIClient, endpoint: Endpoint<NoContent>) async throws -> LoginResult {
        let (data, response) = try await client.sendRaw(endpoint)
        let cookies = SetCookieParser.cookies(from: response)

        if let token = cookies["authToken"], JWTClaims(token: token)?.isAccessToken == true {
            return .authenticated(token: token)
        }

        let decoder = JSONDecoding.makeDecoder()
        if let envelope = try? decoder.decode(APIEnvelope<MFAChallenge>.self, from: data), var challenge = envelope.data,
           challenge.userHasMfa == true || challenge.requiresMfaSetup == true
        {
            challenge.mfaToken = cookies["mfaToken"].flatMap { $0.isEmpty ? nil : $0 }
            return .mfaRequired(challenge)
        }
        throw APIError.unexpectedPayload
    }
}

/// Reads `Set-Cookie` headers, which `URLSession` exposes even without cookie storage. The lookup ignores case (HTTP/2
/// sends `set-cookie`); multiple cookies arrive comma-separated in one field.
enum SetCookieParser {
    static func cookies(from response: HTTPURLResponse) -> [String: String] {
        guard let url = response.url, let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return [:] }
        var result: [String: String] = [:]
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url) {
            result[cookie.name] = cookie.value
        }
        return result
    }
}
