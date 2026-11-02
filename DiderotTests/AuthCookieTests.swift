import Foundation
import Testing
@testable import Diderot

/// The `authToken` cookie given to WebViews and AVFoundation must be as protected as the server's own.
struct AuthCookieTests {
    @Test func matchesTheServerCookie() throws {
        let cookie = try #require(HTTPCookie.docmostAuth(token: "token", serverURL: URL(string: "https://wiki.example.com")))

        #expect(cookie.name == "authToken")
        #expect(cookie.value == "token")
        #expect(cookie.domain == "wiki.example.com")
        #expect(cookie.path == "/")
        #expect(cookie.isHTTPOnly)
        #expect(cookie.sameSitePolicy == .sameSiteLax)
        #expect(cookie.isSecure)
    }

    @Test func secureOnlyForHTTPS() throws {
        let cookie = try #require(HTTPCookie.docmostAuth(token: "token", serverURL: URL(string: "http://localhost:3000")))

        #expect(cookie.domain == "localhost")
        #expect(cookie.isHTTPOnly)
        #expect(!cookie.isSecure)
    }

    @Test func nilWithoutTokenOrHost() {
        #expect(HTTPCookie.docmostAuth(token: nil, serverURL: URL(string: "https://wiki.example.com")) == nil)
        #expect(HTTPCookie.docmostAuth(token: "token", serverURL: nil) == nil)
        #expect(HTTPCookie.docmostAuth(token: "token", serverURL: URL(string: "/p/abc")) == nil)
    }
}

/// The browser sign-in takes the token the server set, not one another host put in the cookie store (code review R12).
struct BrowserLoginTokenTests {
    /// An access token as Docmost signs it (only its claims count here).
    private static let token: String = {
        let payload = Data(#"{"type":"access","exp":4102444800}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "e30.\(payload).sig"
    }()

    /// The cookies a `Set-Cookie` header from `origin` sets.
    private func cookies(_ header: String, from origin: String) -> [HTTPCookie] {
        HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: URL(string: origin)!)
    }

    @Test func takesTheServersOwnCookie() {
        let server = URL(string: "https://example.com")!
        // As Docmost sets it (checked on the dev instances): host only, HttpOnly.
        let own = cookies("authToken=\(Self.token); Path=/; HttpOnly; SameSite=Lax", from: "https://example.com/api/auth/login")
        #expect(BrowserLoginView.authToken(in: own, for: server)?.value == Self.token)
        #expect(BrowserLoginView.authToken(in: own, for: URL(string: "https://EXAMPLE.com")!) != nil)

        // A sibling subdomain's cookie for the parent domain, which the server would get too.
        let sibling = cookies("authToken=\(Self.token); Domain=example.com; Path=/; HttpOnly", from: "https://evil.example.com/")
        #expect(sibling.first?.domain == ".example.com")
        #expect(BrowserLoginView.authToken(in: sibling, for: server) == nil)
        // One a script could have set, another host's, or no access token.
        #expect(BrowserLoginView.authToken(in: cookies("authToken=\(Self.token); Path=/", from: "https://example.com/"), for: server) == nil)
        #expect(BrowserLoginView.authToken(in: own, for: URL(string: "https://wiki.example.com")!) == nil)
        #expect(BrowserLoginView.authToken(in: cookies("authToken=e30.e30.sig; Path=/; HttpOnly", from: "https://example.com/"), for: server) == nil)
    }
}
