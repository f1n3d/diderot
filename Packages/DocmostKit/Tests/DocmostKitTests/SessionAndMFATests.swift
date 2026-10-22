import Foundation
import Testing
@testable import DocmostKit

struct SessionFixtureTests {
    @Test func sessionsListCurrentFirst() throws {
        let list = try TestSupport.decodeFixture(UserSessionList.self, "sessions")
        #expect(!list.sessions.isEmpty)
        #expect(list.sessions.first?.isCurrent == true)
        #expect(list.sessions.contains { $0.deviceName == "iPhone" })
        #expect(list.sessions.allSatisfy { $0.createdAt != nil })
    }

    @Test func ssoURLs() {
        let server = URL(string: "https://wiki.example.com")!
        let oidc = AuthProvider(id: "p1", name: "Keycloak", type: "oidc")
        #expect(Endpoints.SSO.browserLoginURL(server: server, provider: oidc, workspaceId: "w1").absoluteString == "https://wiki.example.com/api/sso/oidc/p1/login")
        let saml = AuthProvider(id: "p2", name: "Okta", type: "saml")
        #expect(Endpoints.SSO.browserLoginURL(server: server, provider: saml, workspaceId: nil).absoluteString == "https://wiki.example.com/api/sso/saml/p2/login")
        let google = AuthProvider(id: "p3", name: "Google", type: "google")
        #expect(Endpoints.SSO.browserLoginURL(server: server, provider: google, workspaceId: "w1").absoluteString == "https://wiki.example.com/api/sso/google/login?workspaceId=w1")
    }
}

extension MockedNetworkingTests {
    struct MFAFlowTests {
        @Test func verifySendsTransferCookieAndCapturesToken() async throws {
            let token = try TestSupport.jwt(claims: ["sub": "u1", "workspaceId": "w1", "type": "access", "exp": 4_102_444_800])
            MockURLProtocol.respond(with: .init(headers: ["Set-Cookie": "authToken=\(token); Path=/; HttpOnly"], body: Data(#"{"success":true,"status":200}"#.utf8)))
            var challenge = MFAChallenge(userHasMfa: true, requiresMfaSetup: false)
            challenge.mfaToken = "transfer-123"
            let result = try await LoginFlow.verifyMFA(client: TestSupport.mockClient(token: nil), challenge: challenge, code: " 123456 ")
            #expect(result == token)

            let request = try #require(MockURLProtocol.recordedRequests.first)
            #expect(request.url?.path() == "/api/mfa/verify")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "mfaToken=transfer-123")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
            #expect(body == ["code": "123456"])
        }

        @Test func verifyWithoutTransferTokenFails() async throws {
            let challenge = MFAChallenge(userHasMfa: true, requiresMfaSetup: false)
            await #expect(throws: APIError.self) {
                try await LoginFlow.verifyMFA(client: TestSupport.mockClient(token: nil), challenge: challenge, code: "000000")
            }
        }

        @Test func ldapLoginCapturesToken() async throws {
            let token = try TestSupport.jwt(claims: ["sub": "u1", "workspaceId": "w1", "type": "access", "exp": 4_102_444_800])
            MockURLProtocol.respond(with: .init(headers: ["Set-Cookie": "authToken=\(token); Path=/; HttpOnly"], body: Data(#"{"success":true,"status":200}"#.utf8)))
            let result = try await LoginFlow.loginWithLDAP(client: TestSupport.mockClient(token: nil), providerId: "ldap1", username: "jane", password: "pw")
            #expect(result == .authenticated(token: token))
            #expect(MockURLProtocol.recordedRequests.first?.url?.path() == "/api/sso/ldap/ldap1/login")
        }
    }
}
