import Foundation
import Testing
@testable import DocmostKit

/// Runs against the local dev instance, only when `DOCMOST_LIVE_URL`, `DOCMOST_LIVE_EMAIL` and either
/// `DOCMOST_LIVE_PASSWORD` or `DOCMOST_LIVE_TOKEN` (used as is) are set. Never point it at production.
enum LiveEnvironment {
    static var url: URL? { ProcessInfo.processInfo.environment["DOCMOST_LIVE_URL"].flatMap(URL.init(string:)) }
    static var email: String? { ProcessInfo.processInfo.environment["DOCMOST_LIVE_EMAIL"] }
    static var password: String? { ProcessInfo.processInfo.environment["DOCMOST_LIVE_PASSWORD"] }
    static var token: String? { ProcessInfo.processInfo.environment["DOCMOST_LIVE_TOKEN"] }
    static var isConfigured: Bool { url != nil && email != nil && (password != nil || token != nil) }
}

/// One sign-in per process; the token is also cached on disk because the server limits sign-ins to 10/min per IP.
actor LiveSession {
    static let shared = LiveSession()

    private struct CachedToken: Codable {
        var key: String
        var token: String
    }

    // The task, not the client: suites run in parallel and call in while the first sign-in still awaits the server.
    private var pending: Task<APIClient, any Error>?

    func client() async throws -> APIClient {
        let task = pending ?? Task {
            guard let url = LiveEnvironment.url, let email = LiveEnvironment.email else {
                throw APIError.invalidResponse
            }
            let token = try await obtainToken(url: url, email: email)
            return APIClient(baseURL: url, token: token, userAgent: "DocmostKitLiveTests/1.0")
        }
        pending = task
        return try await task.value
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "docmost-live-token.json")
    }

    private func obtainToken(url: URL, email: String) async throws -> String {
        if let token = LiveEnvironment.token { return token }
        let key = url.absoluteString + "|" + email

        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedToken.self, from: data),
           cached.key == key,
           let claims = JWTClaims(token: cached.token), !claims.isExpired(at: .now.addingTimeInterval(60))
        {
            let probe = APIClient(baseURL: url, token: cached.token)
            if (try? await probe.send(Endpoints.Users.me)) != nil {
                return cached.token
            }
        }

        guard let password = LiveEnvironment.password else { throw APIError.unauthorized(message: "DOCMOST_LIVE_PASSWORD missing") }
        let result = try await LoginFlow.loginWithPassword(client: APIClient(baseURL: url), email: email, password: password)
        guard case .authenticated(let token) = result else {
            throw APIError.unexpectedPayload
        }
        try? JSONEncoder().encode(CachedToken(key: key, token: token)).write(to: cacheURL, options: .atomic)
        return token
    }
}

@Suite(.serialized, .enabled(if: LiveEnvironment.isConfigured))
struct LiveAPITests {
    @Test func publicWorkspaceIsReachable() async throws {
        let client = APIClient(baseURL: try #require(LiveEnvironment.url))
        let workspace = try await client.send(Endpoints.Workspace.publicInfo)
        #expect(!workspace.name.isEmpty)
    }

    @Test func currentUserMatchesLogin() async throws {
        let client = try await LiveSession.shared.client()
        let me = try await client.send(Endpoints.Users.me)
        #expect(me.user.email.lowercased() == LiveEnvironment.email?.lowercased())
    }

    @Test func entitlementsDecode() async throws {
        let client = try await LiveSession.shared.client()
        let entitlements = try await client.send(Endpoints.Workspace.entitlements)
        #expect(!entitlements.tier.isEmpty)
    }

    @Test func unauthenticatedRequestIs401() async throws {
        let client = APIClient(baseURL: try #require(LiveEnvironment.url))
        await #expect(throws: APIError.unauthorized(message: "Unauthorized")) {
            try await client.send(Endpoints.Users.me)
        }
    }
}
