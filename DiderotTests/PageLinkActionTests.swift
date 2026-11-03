import Foundation
import Testing
@testable import Diderot

/// What a link tapped on a page does: a link to the page itself scrolls or opens its comments, never a second copy of
/// the page.
struct PageLinkActionTests {
    private let server = URL(string: "https://wiki.example.com")!

    /// The page as opened from a link with its slug id ("Ab12Cd34Ef"), its id "p1".
    private func action(_ url: URL) -> PageLinkAction {
        PageLinkAction.action(for: url, serverURL: server, pageIds: ["Ab12Cd34Ef", "p1", "Ab12Cd34Ef"])
    }

    /// What `action` opens, as page, entry and comment: selections compare by their page alone.
    private func opened(_ url: URL) -> [String?]? {
        guard case .open(let selection) = action(url) else { return nil }
        return [selection.pageId, selection.rowId, selection.commentId]
    }

    @Test func linksToThisPageStayOnIt() throws {
        #expect(action(try #require(URL(string: "https://wiki.example.com/s/demo/p/handbuch-Ab12Cd34Ef#section"))) == .scroll(to: "section"))
        #expect(action(try #require(URL(string: "https://wiki.example.com/p/Ab12Cd34Ef"))) == .none)
        #expect(opened(try #require(URL(string: "https://wiki.example.com/p/Zz99Yy88Xx#section"))) == ["Zz99Yy88Xx", nil, nil])
    }

    @Test func commentsShowHereOrOpenWithTheirPage() throws {
        #expect(action(try #require(CommentLink.url(for: "c1"))) == .showComment("c1"))
        #expect(action(ContentLinkRouter.commentWebURL(server: server, slugId: "Ab12Cd34Ef", commentId: "c2")) == .showComment("c2"))
        #expect(opened(ContentLinkRouter.commentWebURL(server: server, slugId: "Zz99Yy88Xx", commentId: "c3")) == ["Zz99Yy88Xx", nil, "c3"])
    }

    @Test func entriesAnchorsAtomsAndOtherLinks() throws {
        let entry = try #require(URL(string: "https://wiki.example.com/s/demo/p/projekte-Ab12Cd34Ef?row=r1&rowBase=b1"))
        #expect(opened(entry) == ["b1", "r1", nil])
        // An entry of this page's own database opens too.
        let own = try #require(URL(string: "https://wiki.example.com/s/demo/p/projekte-Zz99Yy88Xx?row=r2&rowBase=Ab12Cd34Ef"))
        #expect(opened(own) == ["Ab12Cd34Ef", "r2", nil])
        #expect(action(try #require(ContentLinkRouter.url(for: "#fn-1", baseURL: server))) == .anchor("fn-1"))
        #expect(action(try #require(AtomLink.url(block: "b1", type: "status", index: 2))) == .editAtom(block: "b1", type: "status", index: 2))
        #expect(action(ContentLinkRouter.userURL(id: "u1")) == .none)
        let other = try #require(URL(string: "https://docmost.com/s/demo/p/x-Ab12Cd34Ef"))
        #expect(action(other) == .outside(other))
    }
}

/// What a link in shown content opens wherever it shows (`LinkTarget`): a page with its anchor, a database entry or a
/// page's comment; an anchor in what shows; a link that leaves the app; nothing for a user.
struct LinkTargetTests {
    private let server = URL(string: "https://wiki.example.com")!

    /// The page as page, entry and comment, with the anchor; nil for another target.
    private func page(_ text: String) throws -> [String?]? {
        guard case .page(let selection, let anchor) = LinkTarget.of(try #require(URL(string: text)), serverURL: server) else { return nil }
        return [selection.pageId, selection.rowId, selection.commentId, anchor]
    }

    @Test func linksOpenWhatTheyPointTo() throws {
        #expect(try page("https://wiki.example.com/s/demo/p/handbuch-Ab12Cd34Ef#teil") == ["Ab12Cd34Ef", nil, nil, "teil"])
        #expect(try page("https://wiki.example.com/s/demo/p/projekte-Ab12Cd34Ef?row=r1&rowBase=b1") == ["b1", "r1", nil, nil])
        #expect(try page(ContentLinkRouter.commentWebURL(server: server, slugId: "Ab12Cd34Ef", commentId: "c1").absoluteString)
            == ["Ab12Cd34Ef", nil, "c1", nil])
        #expect(LinkTarget.of(try #require(ContentLinkRouter.url(for: "#fn-1", baseURL: server)), serverURL: server) == .anchor("fn-1"))
        #expect(LinkTarget.of(ContentLinkRouter.userURL(id: "u1"), serverURL: server) == LinkTarget.none)
        let other = try #require(URL(string: "https://docmost.com/s/demo/p/x-Ab12Cd34Ef"))
        #expect(LinkTarget.of(other, serverURL: server) == .outside(other))
    }
}
