import Foundation
import Observation
import DocmostKit

/// The user's spaces, shared by the Spaces tab, the Search tab (home screen behind search) and the space picker.
@MainActor
@Observable
final class SpacesStore {
    /// A load started later wins (before, a second one was skipped while one ran).
    private let list = RemoteValue<[Space]>()
    private unowned let session: AppSession

    var state: LoadState<[Space]> { list.state }

    init(session: AppSession) {
        self.session = session
    }

    func loadIfNeeded() async {
        if case .idle = state { await load() }
    }

    /// Shows the cache, then loads from the server; an error surfaces only while nothing is shown.
    func load() async {
        guard let ready = session.ready else { return }
        await list.load(cached: { await ready.cache.read([Space].self, key: CacheKey.spaces) },
                        save: { await ready.cache.write($0, key: CacheKey.spaces) }) {
            try await Paginated.all { cursor in
                try await session.load(Endpoints.Spaces.list(PaginationOptions(limit: 100, cursor: cursor)), of: ready)
            }
        }
    }
}
