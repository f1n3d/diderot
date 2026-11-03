import Foundation
import Testing
@testable import DocmostKit

/// One server however its URL is spelled (`ServerKey`, `Origin`), and the URL a server was added with kept by the
/// sign-ins (`StoredAccounts`).
struct ServerKeyTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func oneServerHoweverSpelled() {
        #expect(ServerKey(url("https://Wiki.example.com:443/")) == ServerKey(url("https://wiki.example.com")))
        #expect(ServerKey(url("HTTP://wiki.example.com:80")) == ServerKey(url("http://wiki.example.com")))
        #expect(ServerKey(url("http://wiki.example.com")) != ServerKey(url("https://wiki.example.com")))
        #expect(ServerKey(url("https://wiki.example.com:8443")) != ServerKey(url("https://wiki.example.com")))
        #expect(ServerKey(url("https://other.example.com")) != ServerKey(url("https://wiki.example.com")))
    }

    @Test func originsFillInTheDefaultPort() {
        #expect(Origin(url("https://Wiki.example.com/p/x")).port == 443)
        #expect(Origin(url("http://wiki.example.com")).port == 80)
        #expect(Origin(url("mailto:jane@example.com")).port == nil)
        #expect(Origin(url("https://wiki.example.com:443/a")) == Origin(url("https://WIKI.example.com/b")))
    }

    /// A server signed in to again in another spelling keeps the one it was added with, its sign-in replaced; any spelling
    /// finds and removes it.
    @Test func signInsKeepTheSpellingTheServerWasAddedWith() {
        var accounts = StoredAccounts()
        accounts.upsert(StoredSession(serverURL: url("https://Wiki.example.com:443"), token: "alt"))
        accounts.upsert(StoredSession(serverURL: url("https://wiki.example.com"), token: "neu"))
        #expect(accounts.sessions.map(\.serverURL) == [url("https://Wiki.example.com:443")])
        #expect(accounts.sessions.map(\.token) == ["neu"])
        #expect(accounts.currentServerURL == url("https://Wiki.example.com:443"))
        #expect(accounts.session(for: url("https://wiki.example.com/"))?.token == "neu")
        accounts.remove(serverURL: url("https://WIKI.example.com"))
        #expect(accounts.sessions.isEmpty && accounts.currentServerURL == nil)
    }
}
