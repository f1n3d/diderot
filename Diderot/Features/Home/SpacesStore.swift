import Foundation
import Observation
import DocmostKit

/// The user's spaces, shared by the Spaces tab, the Search tab (home screen behind search) and the space picker.
@MainActor
@Observable
final class SpacesStore {
    private(set) var state: LoadState<[Space]> = .idle
    private unowned let session: AppSession
    private var isLoading = false

    init(session: AppSession) {
        self.session = session
    }

    func loadIfNeeded() async {
        if case .idle = state { await load() }
    }

    /// Shows the cache, then loads from the server; an error surfaces only while nothing is shown.
    func load() async {
        guard !isLoading, let ready = session.ready else { return }
        isLoading = true
        defer { isLoading = false }
        if state.value == nil {
            if let cached = await ready.cache.read([Space].self, key: CacheKey.spaces) {
                state = .loaded(cached)
            } else {
                state = .loading
            }
        }
        do {
            let spaces = try await Paginated.all { cursor in
                try await session.perform {
                    try await ready.client.send(Endpoints.Spaces.list(PaginationOptions(limit: 100, cursor: cursor)))
                }
            }
            await ready.cache.write(spaces, key: CacheKey.spaces)
            state = .loaded(spaces)
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }
}
