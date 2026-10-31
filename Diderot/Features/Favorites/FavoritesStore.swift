import Foundation
import Observation
import DocmostKit

/// The user's favorites: IDs for the star in the reader, the list for the favorites view. Updates are optimistic.
@MainActor
@Observable
final class FavoritesStore {
    private(set) var pageIds: Set<String> = []
    private(set) var spaceIds: Set<String> = []
    private(set) var listState: LoadState<[Favorite]> = .idle
    /// A change the server didn't take (`MainTabView` shows it): the star or the swiped-away row comes back, and used to
    /// say nothing.
    var toast: String?
    /// Counts list loads, so an older answer arriving last doesn't win.
    @ObservationIgnored private var listLoads = 0
    private unowned let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    func isFavorite(pageId: String) -> Bool { pageIds.contains(pageId) }
    func isFavorite(spaceId: String) -> Bool { spaceIds.contains(spaceId) }

    func loadIds() async {
        guard let client = session.client else { return }
        do {
            async let pages = session.perform { try await client.send(Endpoints.Favorites.ids(type: .page)) }
            async let spaces = session.perform { try await client.send(Endpoints.Favorites.ids(type: .space)) }
            pageIds = Set(try await pages.items)
            spaceIds = Set(try await spaces.items)
        } catch {
            AppLog.ui.debug("Favorite ids failed: \(error.userMessage, privacy: .public)")
        }
    }

    func loadList() async {
        guard let ready = session.ready else { return }
        let client = ready.client
        if listState.value == nil {
            if let cached = await ready.cache.read([Favorite].self, key: CacheKey.favorites) {
                apply(cached)
            } else {
                listState = .loading
            }
        }
        listLoads += 1
        let load = listLoads
        do {
            let favorites = try await Paginated.all { cursor in
                try await session.perform { try await client.send(Endpoints.Favorites.list(cursor: cursor)) }
            }
            guard load == listLoads else { return }
            apply(favorites)
            await ready.cache.write(favorites, key: CacheKey.favorites)
        } catch is CancellationError {
        } catch {
            if listState.value == nil { listState = .failed(error) }
        }
    }

    private func apply(_ favorites: [Favorite]) {
        listState = .loaded(favorites)
        pageIds = Set(favorites.compactMap { $0.favoriteType == .page ? $0.pageId : nil })
        spaceIds = Set(favorites.compactMap { $0.favoriteType == .space ? $0.spaceId : nil })
    }

    func togglePage(_ pageId: String) async {
        guard session.client != nil else { return }
        let wasFavorite = pageIds.contains(pageId)
        if wasFavorite { pageIds.remove(pageId) } else { pageIds.insert(pageId) }
        do {
            _ = try await session.send(wasFavorite ? Endpoints.Favorites.removePage(pageId) : Endpoints.Favorites.addPage(pageId))
            if listState.value != nil { await loadList() }
        } catch {
            if wasFavorite { pageIds.insert(pageId) } else { pageIds.remove(pageId) }
            AppLog.ui.error("Favorite toggle failed: \(error.userMessage, privacy: .public)")
            toast = Self.failure(error, removing: wasFavorite)
        }
    }

    func toggleSpace(_ spaceId: String) async {
        guard session.client != nil else { return }
        let wasFavorite = spaceIds.contains(spaceId)
        if wasFavorite { spaceIds.remove(spaceId) } else { spaceIds.insert(spaceId) }
        do {
            _ = try await session.send(wasFavorite ? Endpoints.Favorites.removeSpace(spaceId) : Endpoints.Favorites.addSpace(spaceId))
            if listState.value != nil { await loadList() }
        } catch {
            if wasFavorite { spaceIds.insert(spaceId) } else { spaceIds.remove(spaceId) }
            AppLog.ui.error("Favorite toggle failed: \(error.userMessage, privacy: .public)")
            toast = Self.failure(error, removing: wasFavorite)
        }
    }

    private static func failure(_ error: Error, removing: Bool) -> String {
        removing
            ? String(localized: "Not removed from Favorites: \(error.userMessage)")
            : String(localized: "Not added to Favorites: \(error.userMessage)")
    }
}
