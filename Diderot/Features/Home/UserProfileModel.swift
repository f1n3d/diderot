import Foundation
import Observation
import DocmostKit

/// A person's profile on Docmost 0.98, as the web's profile page loads it (`user-profile-page.tsx`): who they are, then
/// the pages they created or edited last and the spaces both people share. The lists load once the profile has, as
/// there: a person who isn't there gets "Profile not found" without them.
@MainActor
@Observable
final class UserProfileModel {
    let userId: String
    private(set) var profile: LoadState<UserProfile> = .idle
    let recentPages: ProfileListing<UserRecentPage>
    let spaces: ProfileListing<UserProfileSpace>
    /// A failed "Load More", or a failed refresh of what shows.
    var toast: String?
    @ObservationIgnored private unowned let session: AppSession
    /// Only the newest load's answer shows.
    @ObservationIgnored private var loads = 0

    init(userId: String, session: AppSession) {
        self.userId = userId
        self.session = session
        recentPages = ProfileListing { Endpoints.Users.recentPages(userId: userId, cursor: $0) }
        spaces = ProfileListing { Endpoints.Users.spaces(userId: userId, cursor: $0) }
    }

    /// The user's own profile: the lists' empty states speak to them.
    var isSelf: Bool { session.ready?.currentUser.user.id == userId }

    /// The profile isn't there for the user, as the web's `notFound`: the server doesn't know the id (404, also what a
    /// deactivated or deleted person is for someone who doesn't manage members), or the id is no UUID.
    var isNotFound: Bool {
        guard case .failed(let error) = profile else { return false }
        return Self.isNotFound(error)
    }

    nonisolated static func isNotFound(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .notFound, .forbidden, .validation: true
        default: false
        }
    }

    /// The profile, then both lists. A failed refresh keeps what shows and says why, unless the person is gone.
    func load() async {
        guard let ready = session.ready else { return }
        loads += 1
        let load = loads
        // The web asks for no other id, and the server would refuse it (400).
        guard UUID(uuidString: userId) != nil else {
            profile = .failed(APIError.notFound(message: nil))
            return
        }
        if profile.value == nil { profile = .loading }
        do {
            let loaded = try await session.load(Endpoints.Users.info(userId: userId), of: ready)
            guard load == loads else { return }
            profile = .loaded(loaded)
        } catch is CancellationError {
            return
        } catch {
            guard load == loads else { return }
            if profile.value == nil || Self.isNotFound(error) {
                profile = .failed(error)
            } else {
                toast = error.userMessage
            }
            return
        }
        await loadLists()
    }

    /// What isn't there yet: back from a page or space opened here, a load that leaving cancelled starts again.
    func loadIfNeeded() async {
        guard profile.value != nil else {
            await load()
            return
        }
        await loadListsIfNeeded()
    }

    /// The lists that show no first page yet (not loaded, cancelled, failed). The own profile loads only these, under
    /// what the session knows of the user.
    func loadListsIfNeeded() async {
        async let pages: Void = reloadIfEmpty(recentPages)
        async let shared: Void = reloadIfEmpty(spaces)
        _ = await (pages, shared)
    }

    /// A list's first page again ("Try Again").
    func reload<Item>(_ list: ProfileListing<Item>) async {
        if let error = await firstPage(of: list) { toast = error.userMessage }
    }

    func loadMore<Item>(_ list: ProfileListing<Item>) async {
        guard let ready = session.ready else { return }
        if let error = await list.loadMore(session: session, of: ready) { toast = error.userMessage }
    }

    /// Both lists' first pages, at once.
    private func loadLists() async {
        async let pages = firstPage(of: recentPages)
        async let shared = firstPage(of: spaces)
        if let error = await [pages, shared].compactMap({ $0 }).first { toast = error.userMessage }
    }

    private func reloadIfEmpty<Item>(_ list: ProfileListing<Item>) async {
        if list.state.value == nil { await reload(list) }
    }

    private func firstPage<Item>(of list: ProfileListing<Item>) async -> (any Error)? {
        guard let ready = session.ready else { return nil }
        return await list.load(session: session, of: ready)
    }
}

/// One of a profile's lists, ten at a time as on the web (`useUserRecentPagesQuery`, `useUserSpacesQuery`): the first
/// page, then the next from its cursor with "Load More".
@MainActor
@Observable
final class ProfileListing<Item: Decodable & Sendable & Identifiable> {
    /// The first page's load, then all that loaded since.
    private(set) var state: LoadState<[Item]> = .idle
    /// Where the next page starts; nil once no more follow.
    private(set) var cursor: String?
    private(set) var isLoadingMore = false
    @ObservationIgnored private let endpoint: (_ cursor: String?) -> Endpoint<Paginated<Item>>
    /// Only the newest first load's answer shows.
    @ObservationIgnored private var loads = 0

    init(_ endpoint: @escaping (_ cursor: String?) -> Endpoint<Paginated<Item>>) {
        self.endpoint = endpoint
    }

    var hasMore: Bool { cursor != nil }

    /// The first page in place of what shows. Returns the error of a failed refresh, which keeps what shows.
    func load(session: AppSession, of owner: ReadySession) async -> (any Error)? {
        loads += 1
        let load = loads
        if state.value == nil { state = .loading }
        do {
            let page = try await session.load(endpoint(nil), of: owner)
            guard load == loads else { return nil }
            state = .loaded(Self.unique(page.items))
            cursor = page.meta.hasNextPage ? page.meta.nextCursor : nil
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard load == loads else { return nil }
            guard state.value != nil else {
                state = .failed(error)
                return nil
            }
            return error
        }
    }

    /// The page after what shows. Dropped unless the list still ends where it started (a refresh came in between);
    /// returns the error of a failed one, which leaves the list as it is.
    func loadMore(session: AppSession, of owner: ReadySession) async -> (any Error)? {
        guard let start = cursor, !isLoadingMore, state.value != nil else { return nil }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await session.load(endpoint(start), of: owner)
            guard cursor == start, let shown = state.value else { return nil }
            state = .loaded(Self.unique(shown + page.items))
            cursor = page.meta.hasNextPage ? page.meta.nextCursor : nil
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return cursor == start ? error : nil
        }
    }

    /// Each item once: a page edited or a space renamed between two loads can come again, and a list shows its rows by id.
    private static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
