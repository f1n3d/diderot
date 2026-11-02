import Foundation
import Observation

/// Counts changes made by the app (new page, title, trash, …) so the page tree and lists reload.
@MainActor
@Observable
final class ContentChanges {
    private(set) var version = 0
    private(set) var lastChangedSpaceId: String?

    func pageChanged(in spaceId: String?) {
        lastChangedSpaceId = spaceId
        version += 1
    }

    /// Pages in these spaces changed at once (kept titles going out): views see one change of `version` for all of
    /// them, so several spaces count as all, and every space's open view reloads, not only the last one's.
    func pagesChanged(in spaceIds: [String]) {
        let spaces = Set(spaceIds)
        guard !spaces.isEmpty else { return }
        pageChanged(in: spaces.count == 1 ? spaces.first : nil)
    }
}
