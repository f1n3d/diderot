import Foundation

/// What a link tapped in shown content opens, wherever it shows (a page, a version, a presentation, a template): a page,
/// a database entry or a page's comment; an anchor in what shows; a link that leaves the app; or nothing (a user).
/// Where it shows decides what it does with each (`PageLinkAction` for a page).
enum LinkTarget: Equatable {
    case page(PageSelection, anchor: String?)
    case anchor(String)
    case outside(URL)
    case none

    static func of(_ url: URL, serverURL: URL?) -> LinkTarget {
        switch ContentLinkRouter.destination(for: url, serverURL: serverURL) {
        case .page(let slugId, let anchor): .page(PageSelection(pageId: slugId), anchor: anchor)
        case .databaseEntry(let basePageId, let rowId): .page(PageSelection(pageId: basePageId, rowId: rowId), anchor: nil)
        case .comment(let slugId, let commentId): .page(PageSelection(pageId: slugId, commentId: commentId), anchor: nil)
        case .anchor(let anchor): .anchor(anchor)
        case .user: .none
        case .external(let external): .outside(external)
        }
    }
}

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
        switch LinkTarget.of(url, serverURL: serverURL) {
        case .page(let selection, let anchor):
            // An entry opens in its database, also one of this page's.
            guard selection.rowId == nil, pageIds.contains(selection.pageId) else { return .open(selection) }
            if let commentId = selection.commentId { return .showComment(commentId) }
            return anchor.map { .scroll(to: $0) } ?? .none
        case .anchor(let anchor):
            return .anchor(anchor)
        case .outside(let external):
            return .outside(external)
        case .none:
            return .none
        }
    }
}
