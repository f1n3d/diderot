import Foundation
import DocmostKit

/// Selected page for the detail column; `title` only shows until the page loads.
struct PageSelection: Hashable, Sendable {
    let pageId: String
    var title: String?
    /// Newly created page: start editing the title right away.
    var focusTitle = false
    /// Database page: entry to open once it has loaded (a link to the entry).
    var rowId: String?

    init(pageId: String, title: String? = nil, rowId: String? = nil) {
        self.pageId = pageId
        self.title = title
        self.rowId = rowId
    }

    init(page: SidebarPage) {
        self.init(pageId: page.id, title: page.title)
    }

    init(page: Page) {
        self.init(pageId: page.id, title: page.title)
    }

    static func == (lhs: PageSelection, rhs: PageSelection) -> Bool { lhs.pageId == rhs.pageId }
    func hash(into hasher: inout Hasher) { hasher.combine(pageId) }
}
