import Foundation

/// What a link tapped on a page does (`PageView`): decided from the link and the page alone.
enum PageLinkAction: Equatable {
    /// A comment of this page: the comments open on it.
    case showComment(String)
    /// A status, math or integration atom while editing (`AtomLink`): its sheet opens.
    case editAtom(block: String, type: String, index: Int)
    /// A link to this page with an anchor: the page scrolls there.
    case scroll(to: String)
    /// A `#anchor`: while editing, a footnote reference goes into the footnote's text, like a double-click in the web
    /// editor; else the page scrolls there.
    case anchor(String)
    /// Another page, a database's entry or another page's comment.
    case open(PageSelection)
    /// A link that leaves the app.
    case outside(URL)
    /// A link to this page without an anchor, or to a user.
    case none

    /// `pageIds`: this page's slug id and id, and the one it was opened with; a link to them never opens a second copy of
    /// the page.
    static func action(for url: URL, serverURL: URL?, pageIds: [String?]) -> PageLinkAction {
        if let commentId = CommentLink.commentId(from: url) { return .showComment(commentId) }
        if let atom = AtomLink.parse(url) { return .editAtom(block: atom.block, type: atom.type, index: atom.index) }
        switch ContentLinkRouter.destination(for: url, serverURL: serverURL) {
        case .page(let slugId, let anchor):
            guard pageIds.contains(slugId) else { return .open(PageSelection(pageId: slugId)) }
            return anchor.map { .scroll(to: $0) } ?? .none
        case .databaseEntry(let basePageId, let rowId):
            return .open(PageSelection(pageId: basePageId, rowId: rowId))
        case .comment(let slugId, let commentId):
            return pageIds.contains(slugId) ? .showComment(commentId) : .open(PageSelection(pageId: slugId, commentId: commentId))
        case .anchor(let anchor):
            return .anchor(anchor)
        case .user:
            return .none
        case .external(let external):
            return .outside(external)
        }
    }
}
