import Foundation
import Synchronization
import Testing
@testable import DocmostKit

/// Every suite using the global `MockURLProtocol` state must nest here (via an extension, also from other files):
/// `.serialized` applies recursively, so they run one at a time; on separate top-level suites it wouldn't stop peers
/// running in parallel.
@Suite(.serialized)
struct MockedNetworkingTests {}

extension MockedNetworkingTests {
struct APIClientTests {
    @Test func sendsBearerUserAgentAndEmptyJSONBody() async throws {
        MockURLProtocol.respond(with: .init(body: Data(#"{"data":{"cloud":false,"tier":"free","features":[]},"success":true,"status":200}"#.utf8)))
        let client = TestSupport.mockClient(token: "abc")
        _ = try await client.send(Endpoints.Workspace.entitlements)

        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.url?.absoluteString == "http://localhost:3000/api/workspace/entitlements")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "DocmostKitTests/1.0")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == "{}")
    }

    @Test func publicEndpointSendsNoAuthorization() async throws {
        MockURLProtocol.respond(with: .init(body: try TestSupport.fixture("workspace-public")))
        let client = TestSupport.mockClient(token: "abc")
        let workspace = try await client.send(Endpoints.Workspace.publicInfo)
        #expect(workspace.name == "Docmost Dev")
        #expect(workspace.providers.isEmpty)
        #expect(MockURLProtocol.recordedRequests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func decodesCurrentUserFixture() async throws {
        MockURLProtocol.respond(with: .init(body: try TestSupport.fixture("users-me")))
        let me = try await TestSupport.mockClient().send(Endpoints.Users.me)
        #expect(me.user.email == "admin@docmost.local")
        #expect(me.user.workspaceRole == .owner)
        #expect(me.user.displayName == "Dev Admin")
        #expect(me.workspace.name == "Docmost Dev")
        #expect(me.workspace.memberCount == 1)
        #expect(me.user.id == "01a11a90-f71c-707b-ba76-800020050b3d")
    }

    @Test func voidResponseDecodesAsNoContent() async throws {
        MockURLProtocol.respond(with: .init(body: try TestSupport.fixture("void-response")))
        let result = try await TestSupport.mockClient().send(Endpoints.Auth.logout)
        #expect(result == NoContent())
    }

    @Test func serverClockOffsetComesFromTheDateHeader() async throws {
        let serverNow = Date.now.addingTimeInterval(3600)
        MockURLProtocol.respond(with: .init(headers: ["Date": serverNow.formatted(.http)], body: try TestSupport.fixture("void-response")))
        let client = TestSupport.mockClient()
        #expect(client.serverClockOffset == 0)
        _ = try await client.send(Endpoints.Auth.logout)
        #expect(abs(client.serverClockOffset - 3600) < 2)
    }

    @Test func versionRequestWaitsBriefly() async throws {
        MockURLProtocol.respond(with: .init(body: Data(#"{"data":{"currentVersion":"0.96.0","latestVersion":"0.96.0"},"success":true,"status":200}"#.utf8)))
        let version = try await TestSupport.mockClient().send(Endpoints.Version.info)
        #expect(version.currentVersion == "0.96.0")
        #expect(MockURLProtocol.recordedRequests.first?.timeoutInterval == 3)
    }

    @Test func missingPayloadIsAnError() async throws {
        MockURLProtocol.respond(with: .init(body: try TestSupport.fixture("void-response")))
        await #expect(throws: APIError.unexpectedPayload) {
            try await TestSupport.mockClient().send(Endpoints.Users.me)
        }
    }

    @Test func mapsUnauthorized() async throws {
        MockURLProtocol.respond(with: .init(status: 401, body: try TestSupport.fixture("error-401-login")))
        await #expect(throws: APIError.unauthorized(message: "Email or password does not match")) {
            try await TestSupport.mockClient().send(Endpoints.Users.me)
        }
    }

    @Test func mapsValidationMessages() async throws {
        MockURLProtocol.respond(with: .init(status: 400, body: try TestSupport.fixture("error-400-validation")))
        await #expect(throws: APIError.validation(messages: ["email must be an email", "password should not be empty"])) {
            try await TestSupport.mockClient().send(Endpoints.Users.me)
        }
    }

    /// A 403 or 404 counts as gone (the saved copy goes) only with Docmost's error body; a proxy's or captive portal's
    /// page is a plain server error.
    @Test func goneNeedsDocmostsErrorBody() async throws {
        MockURLProtocol.respond(with: .init(status: 404, body: Data("<html>Sign in to the Wi-Fi</html>".utf8)))
        await #expect(throws: APIError.server(status: 404, message: nil)) {
            try await TestSupport.mockClient().send(Endpoints.Users.me)
        }
        MockURLProtocol.respond(with: .init(status: 403, body: Data(#"{"statusCode":403,"message":"Forbidden"}"#.utf8)))
        await #expect(throws: APIError.forbidden(message: "Forbidden")) {
            try await TestSupport.mockClient().send(Endpoints.Users.me)
        }
    }

    @Test func mapsNotFoundAndThrottled() async throws {
        MockURLProtocol.respond(with: .init(status: 404, body: try TestSupport.fixture("error-404")))
        await #expect(throws: APIError.notFound(message: "Space not found")) {
            try await TestSupport.mockClient().send(Endpoints.Users.me)
        }

        MockURLProtocol.respond(with: .init(status: 429, body: Data(#"{"statusCode":429,"message":"Too many requests"}"#.utf8)))
        await #expect(throws: APIError.throttled) {
            try await TestSupport.mockClient().send(Endpoints.Users.me)
        }
    }

    /// Typing on in search or leaving a screen cancels the request's task: no network error, and nothing is logged.
    /// URLSession reports that as `URLError(.cancelled)`, whether the request was in flight or not started yet.
    @Test func cancelledTaskThrowsCancellationError() async throws {
        MockURLProtocol.respond(with: .init(error: URLError(.cancelled)))
        let logged = Mutex(0)
        let client = TestSupport.mockClient(logger: { _ in logged.withLock { $0 += 1 } })
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(Endpoints.Users.me)
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(logged.withLock { $0 } == 0)
    }

    /// Only the caller's cancellation is no failure; `URLError(.cancelled)` while its task runs on is a network error.
    @Test func cancelledURLRequestOutsideACancelledTaskIsANetworkError() async throws {
        MockURLProtocol.respond(with: .init(error: URLError(.cancelled)))
        let error = await #expect(throws: APIError.self) { try await TestSupport.mockClient().send(Endpoints.Users.me) }
        guard case .network(let urlError)? = error else {
            Issue.record("Expected a network error, got \(String(describing: error))")
            return
        }
        #expect(urlError.code == .cancelled)
    }

    @Test func fileURLsAreBuiltRelativeToBase() {
        let client = APIClient(baseURL: URL(string: "https://wiki.example.com/")!)
        #expect(client.apiURL("files/abc/cat.png").absoluteString == "https://wiki.example.com/api/files/abc/cat.png")
        #expect(client.apiURL("/users/me").absoluteString == "https://wiki.example.com/api/users/me")
    }

    @Test func fetchFileSendsNoTokenToForeignHost() async throws {
        MockURLProtocol.respond(with: .init())
        _ = try await TestSupport.mockClient(token: "abc").fetchFile(at: URL(string: "https://attacker.example/x.png")!)
        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchFileSendsTokenToOwnServer() async throws {
        MockURLProtocol.respond(with: .init())
        _ = try await TestSupport.mockClient(token: "abc").fetchFile(at: URL(string: "http://localhost:3000/api/files/abc/cat.png")!)
        // Same origin: a missing port is the scheme's default, scheme and host ignore case.
        let wiki = TestSupport.mockClient(token: "abc", baseURL: URL(string: "https://wiki.example.com")!)
        _ = try await wiki.fetchFile(at: URL(string: "HTTPS://Wiki.Example.com:443/api/files/abc/cat.png")!)
        #expect(MockURLProtocol.recordedRequests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer abc", "Bearer abc"])
    }

    @Test func fetchFileLogsFolderWithoutFileName() async throws {
        MockURLProtocol.respond(with: .init())
        let paths = Mutex<[String]>([])
        let client = TestSupport.mockClient(logger: { entry in paths.withLock { $0.append(entry.path) } })
        _ = try await client.fetchFile(at: URL(string: "http://localhost:3000/api/files/abc/secret-name.pdf")!)
        #expect(paths.withLock { $0 } == ["/api/files/abc"])
    }

    @Test func uploadSendsMultipartAndDecodesBareAttachment() async throws {
        // files/upload answers without an envelope (`res.send`).
        MockURLProtocol.respond(with: .init(body: Data(#"{"id":"a1","fileName":"cat.png","fileSize":3,"mimeType":"image/png","url":"/api/files/a1/cat.png"}"#.utf8)))
        let attachment = try await TestSupport.mockClient(token: "abc").uploadAttachment(
            pageId: "p1", fileName: "my \"cat\".png", mimeType: "image/png", data: Data("PNG".utf8)
        )
        #expect(attachment.id == "a1")

        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.url?.absoluteString == "http://localhost:3000/api/files/upload")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = contentType.trimmingPrefix("multipart/form-data; boundary=")
        let expected = "--\(boundary)\r\nContent-Disposition: form-data; name=\"pageId\"\r\n\r\np1\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"my _cat_.png\"\r\nContent-Type: image/png\r\n\r\nPNG\r\n"
            + "--\(boundary)--\r\n"
        #expect(request.httpBody == Data(expected.utf8))
    }
}

struct LoginFlowTests {
    @Test func capturesAccessTokenFromSetCookie() async throws {
        let token = try TestSupport.jwt(claims: ["sub": "u1", "workspaceId": "w1", "type": "access", "exp": 4_102_444_800])
        MockURLProtocol.respond(with: .init(
            headers: [
                "Set-Cookie": "mfaToken=; Max-Age=0; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; SameSite=Lax, authToken=\(token); Path=/; Expires=Wed, 06 Jan 2027 08:11:20 GMT; HttpOnly; SameSite=Lax",
            ],
            body: Data(#"{"success":true,"status":200}"#.utf8)
        ))
        let result = try await LoginFlow.loginWithPassword(client: TestSupport.mockClient(token: nil), email: "a@b.c", password: "secret")
        #expect(result == .authenticated(token: token))

        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
        #expect(body == ["email": "a@b.c", "password": "secret"])
    }

    @Test func reportsMFAChallenge() async throws {
        MockURLProtocol.respond(with: .init(
            headers: ["Set-Cookie": "mfaToken=transfer-123; Path=/; HttpOnly"],
            body: Data(#"{"data":{"userHasMfa":true,"requiresMfaSetup":false,"isMfaEnforced":false},"success":true,"status":200}"#.utf8)
        ))
        let result = try await LoginFlow.loginWithPassword(client: TestSupport.mockClient(token: nil), email: "a@b.c", password: "secret")
        guard case .mfaRequired(let challenge) = result else {
            Issue.record("Expected MFA challenge, got \(result)")
            return
        }
        #expect(challenge.userHasMfa == true)
        #expect(challenge.mfaToken == "transfer-123")
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        MockURLProtocol.respond(with: .init(status: 401, body: try TestSupport.fixture("error-401-login")))
        await #expect(throws: APIError.unauthorized(message: "Email or password does not match")) {
            try await LoginFlow.loginWithPassword(client: TestSupport.mockClient(token: nil), email: "a@b.c", password: "nope")
        }
    }
}

}
