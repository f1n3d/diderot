import Foundation
import Testing
@testable import Diderot

struct ContentLinkRouterTests {
    private let server = URL(string: "https://wiki.example.com")!

    @Test func classifiesServerPageLinks() {
        let url = URL(string: "https://wiki.example.com/s/demo/p/handbuch-Ab12Cd34Ef#section")!
        #expect(ContentLinkRouter.destination(for: url, serverURL: server) == .page(slugId: "Ab12Cd34Ef", anchor: "section"))

        let short = URL(string: "https://wiki.example.com/p/Ab12Cd34Ef")!
        #expect(ContentLinkRouter.destination(for: short, serverURL: server) == .page(slugId: "Ab12Cd34Ef", anchor: nil))

        let share = URL(string: "https://wiki.example.com/share/abc123def4/p/some-title-Zz99Yy88Xx")!
        #expect(ContentLinkRouter.destination(for: share, serverURL: server) == .page(slugId: "Zz99Yy88Xx", anchor: nil))

        let docs = URL(string: "https://wiki.example.com/docs/demo/intro-Qq11Ww22Ee")!
        #expect(ContentLinkRouter.destination(for: docs, serverURL: server) == .page(slugId: "Qq11Ww22Ee", anchor: nil))

        let uuid = URL(string: "https://wiki.example.com/p/01a11ad8-2e09-718d-820a-da24be7aa8e5")!
        #expect(ContentLinkRouter.destination(for: uuid, serverURL: server) == .page(slugId: "01a11ad8-2e09-718d-820a-da24be7aa8e5", anchor: nil))
    }

    /// A link to a database entry, copied in the web, opens its database (also one embedded in the linked page).
    @Test func classifiesDatabaseEntryLinks() {
        let entry = URL(string: "https://wiki.example.com/s/demo/p/projekte-Ab12Cd34Ef?row=r1&rowBase=b1")!
        #expect(ContentLinkRouter.destination(for: entry, serverURL: server) == .databaseEntry(basePageId: "b1", rowId: "r1"))
        let half = URL(string: "https://wiki.example.com/s/demo/p/projekte-Ab12Cd34Ef?row=r1")!
        #expect(ContentLinkRouter.destination(for: half, serverURL: server) == .page(slugId: "Ab12Cd34Ef", anchor: nil))
    }

    /// An anchor link reaches its anchor unchanged, also with "/" or an escaped character in it.
    @Test func anchorLinksKeepTheirAnchor() throws {
        for (href, anchor) in [("#a/b", "a/b"), ("#a%20b", "a b"), ("#a%2520b", "a%20b"), ("#plain", "plain")] {
            let url = try #require(ContentLinkRouter.url(for: href, baseURL: server))
            #expect(ContentLinkRouter.destination(for: url, serverURL: server) == .anchor(anchor), "\(href)")
        }
    }

    @Test func otherHostsAndNonPagePathsAreExternal() {
        let other = URL(string: "https://docmost.com/s/demo/p/x-Ab12Cd34Ef")!
        #expect(ContentLinkRouter.destination(for: other, serverURL: server) == .external(other))

        let settings = URL(string: "https://wiki.example.com/settings/account")!
        #expect(ContentLinkRouter.destination(for: settings, serverURL: server) == .external(settings))

        let mail = URL(string: "mailto:someone@example.com")!
        #expect(ContentLinkRouter.destination(for: mail, serverURL: server) == .external(mail))
    }

    @Test func portMustMatch() {
        let dev = URL(string: "http://localhost:3000")!
        let page = URL(string: "http://localhost:3000/s/demo/p/x-Ab12Cd34Ef")!
        #expect(ContentLinkRouter.destination(for: page, serverURL: dev) == .page(slugId: "Ab12Cd34Ef", anchor: nil))
        let otherPort = URL(string: "http://localhost:4000/s/demo/p/x-Ab12Cd34Ef")!
        #expect(ContentLinkRouter.destination(for: otherPort, serverURL: dev) == .external(otherPort))
    }

    @Test func buildsURLsFromDocumentHrefs() {
        #expect(ContentLinkRouter.url(for: "#heading1", baseURL: server)?.absoluteString == "docmost-internal://anchor/heading1")
        #expect(ContentLinkRouter.url(for: "/s/demo/p/x-Ab12Cd34Ef", baseURL: server)?.absoluteString == "https://wiki.example.com/s/demo/p/x-Ab12Cd34Ef")
        #expect(ContentLinkRouter.url(for: "https://docmost.com", baseURL: server)?.absoluteString == "https://docmost.com")
        #expect(ContentLinkRouter.url(for: "example.com/path", baseURL: server)?.absoluteString == "https://example.com/path")
        #expect(ContentLinkRouter.url(for: "   ", baseURL: server) == nil)
    }

    @Test func normalizesTypedLinksLikeTheWeb() {
        #expect(ContentLinkRouter.normalizedLink("docmost.com")?.absoluteString == "https://docmost.com")
        #expect(ContentLinkRouter.normalizedLink(" https://x.com ")?.absoluteString == "https://x.com")
        #expect(ContentLinkRouter.normalizedLink("/p/abc")?.absoluteString == "/p/abc")
        #expect(ContentLinkRouter.normalizedLink("#heading")?.absoluteString == "#heading")
        #expect(ContentLinkRouter.normalizedLink("mailto:a@b.c")?.absoluteString == "mailto:a@b.c")
        #expect(ContentLinkRouter.normalizedLink("   ") == nil)
        #expect(ContentLinkRouter.normalizedLink("hello world") == nil)
    }

    @Test func internalSchemeRoundTrips() throws {
        let page = ContentLinkRouter.pageURL(slugId: "Ab12Cd34Ef", anchor: "top")
        #expect(ContentLinkRouter.destination(for: page, serverURL: server) == .page(slugId: "Ab12Cd34Ef", anchor: "top"))
        let anchor = try #require(ContentLinkRouter.url(for: "#fn one", baseURL: nil))
        #expect(ContentLinkRouter.destination(for: anchor, serverURL: server) == .anchor("fn one"))
        let user = ContentLinkRouter.userURL(id: "u1")
        #expect(ContentLinkRouter.destination(for: user, serverURL: server) == .user(id: "u1"))
    }

    @Test func webPageURLRoundTrips() {
        let page = ContentLinkRouter.webPageURL(server: server, slugId: "Ab12Cd34Ef")
        #expect(page.absoluteString == "https://wiki.example.com/p/Ab12Cd34Ef")
        #expect(ContentLinkRouter.destination(for: page, serverURL: server) == .page(slugId: "Ab12Cd34Ef", anchor: nil))
        // `destination` ignores the server's path, so check the prefix in the string too.
        let prefixed = URL(string: "https://example.com/wiki")!
        let nested = ContentLinkRouter.webPageURL(server: prefixed, slugId: "Ab12Cd34Ef")
        #expect(nested.absoluteString == "https://example.com/wiki/p/Ab12Cd34Ef")
        #expect(ContentLinkRouter.destination(for: nested, serverURL: prefixed) == .page(slugId: "Ab12Cd34Ef", anchor: nil))
    }
}
