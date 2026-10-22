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
