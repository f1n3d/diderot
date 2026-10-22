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
}
