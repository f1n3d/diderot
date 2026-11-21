import Foundation

/// Keys in a server's offline cache (`DiskCache`) and in its unsent changes (`UnsentChanges`).
enum CacheKey {
    static let currentUser = "users/me"
    static let entitlements = "workspace/entitlements"
    /// The server's last known Docmost version.
    static let serverVersion = "version"
    static let spaces = "spaces"
    static let recent = "pages/recent"
    static let favorites = "favorites"
    static let recentlyOpened = "recentlyOpened"
    static func page(_ id: String) -> String { "page/\(id)" }
    /// Yjs state with changes the server hadn't confirmed when the page closed (in `UnsentChanges`).
    static func unsentChanges(_ pageId: String) -> String { "unsent/\(pageId)" }
    /// The document with them, shown while offline.
    static func unsentDocument(_ pageId: String) -> String { "unsentDocument/\(pageId)" }
    /// Page titles the server didn't get, by page id (`UnsentTitle`).
    static let unsentTitles = "unsentTitles"
    /// Database fields the server didn't get, by `UnsentCell.key`.
    static let unsentCells = "unsentCells"
    /// The note being written for the page in "Append Note" (`NoteDraft`).
    static func noteDraft(_ pageId: String) -> String { "noteDraft/\(pageId)" }
    static func breadcrumbs(_ pageId: String) -> String { "breadcrumbs/\(pageId)" }
    static func base(_ pageId: String) -> String { "base/\(pageId)" }
    static func baseView(_ pageId: String, viewId: String) -> String { "base/\(pageId)/view/\(viewId)" }
    static func tree(spaceId: String, parentPageId: String?) -> String { "tree/\(spaceId)/\(parentPageId ?? "root")" }
}
