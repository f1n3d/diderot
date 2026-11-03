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
        #expect(action(try #require(ContentLinkRouter.url(for: "#fn-1", baseURL: server))) == .anchor("fn-1"))
        #expect(action(try #require(AtomLink.url(block: "b1", type: "status", index: 2))) == .editAtom(block: "b1", type: "status", index: 2))
        #expect(action(ContentLinkRouter.userURL(id: "u1")) == .none)
        let other = try #require(URL(string: "https://docmost.com/s/demo/p/x-Ab12Cd34Ef"))
        #expect(action(other) == .outside(other))
    }
}
