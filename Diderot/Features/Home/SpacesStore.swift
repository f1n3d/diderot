import Foundation
import Observation
import DocmostKit

/// The user's spaces, shared by the Spaces tab, the Search tab (home screen behind search) and the space picker. Archived
/// ones (Docmost 0.98) are among them: a page there still needs its space's role and name.
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
                try await session.load(Endpoints.Spaces.list(PaginationOptions(limit: 100, cursor: cursor), status: .all), of: ready)
            }
        }
    }

    /// The order of the Spaces tab: the active spaces by name as the server sorts them, then the archived ones, as the
    /// web lists them apart.
    static func activeFirst(_ spaces: [Space]) -> [Space] {
        spaces.filter { !$0.isArchived } + spaces.filter(\.isArchived)
    }
}
