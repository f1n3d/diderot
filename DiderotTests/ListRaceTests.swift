import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Notifications, favorites, comments and search: a late answer keeps the newer list, filter or query; a failed change says so.
    @Suite struct Lists: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// Marking notifications read without a connection: list and badge must not look done until the next poll.
        @Test func failedMarkReadKeepsNotificationsUnread() async throws {
            let session = try await sessionOnA()
            let notifications = NotificationsStore(session: session)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [{"id": "n1", "type": "page.updated"}], "meta": {"hasNextPage": false}}}"# }
            await notifications.loadList()
            StubURLProtocol.body.withLock { $0 = nil }
            let notification = try #require(notifications.listState.value?.first)
            StubURLProtocol.offline.withLock { $0 = true }
            await notifications.markRead(notification)
            #expect(notifications.listState.value?.first?.isUnread == true && notifications.unreadCount == 1)
            #expect(notifications.toast?.hasPrefix(String(localized: "Not marked as read: \("")")) == true, "and says so")
            await notifications.markAllRead()
            #expect(notifications.listState.value?.first?.isUnread == true && notifications.unreadCount == 1)
            StubURLProtocol.offline.withLock { $0 = false }
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// The user switches from Direct to All while Direct loads, and the All list arrives first.
        @Test func lateNotificationsAnswerKeepsTheNewFilter() async throws {
            let session = try await sessionOnA()
            let notifications = NotificationsStore(session: session)
            notifications.filter = .direct
            let direct = #"{"data": {"items": [], "meta": {"hasNextPage": false}}}"#
            StubURLProtocol.body.withLock { $0 = direct }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                notifications.filter = .all
                StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [{"id": "n1", "type": "page.updated"}], "meta": {"hasNextPage": false}}}"# }
                await notifications.loadList()
                StubURLProtocol.body.withLock { $0 = direct }
            } }
            await notifications.loadList()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(notifications.listState.value?.map(\.id) == ["n1"] && notifications.unreadCount == 1)
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// Two favorites loads overlap (opening the tab, a rename's change) and the older answer arrives last: the newer
        /// list stays, with the new title.
        @Test func lateFavoritesAnswerKeepsTheNewerList() async throws {
            let session = try await sessionOnA()
            let favorites = FavoritesStore(session: session)
            func list(_ title: String) -> String {
                #"{"data": {"items": [{"id": "f1", "type": "page", "pageId": "p1", "page": {"id": "p1", "title": "\#(title)"}}], "meta": {"hasNextPage": false}}}"#
            }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = list("Neu") }
                await favorites.loadList()
                StubURLProtocol.body.withLock { $0 = list("Alt") }
            } }
            await favorites.loadList()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(favorites.listState.value?.first?.page?.title == "Neu")
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// A favorite the server didn't take comes back and says so; it used to come back without a word.
        @Test func failedFavoriteChangeSaysSo() async throws {
            let session = try await sessionOnA()
            let favorites = FavoritesStore(session: session)
            StubURLProtocol.offline.withLock { $0 = true }
            await favorites.togglePage("p1")
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(!favorites.isFavorite(pageId: "p1"))
            #expect(favorites.toast?.hasPrefix(String(localized: "Not added to Favorites: \("")")) == true)
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// A slow comments load that ends after a newer one doesn't overwrite it: a comment just posted disappeared from the
        /// list and the badge, and a deleted one came back.
        @Test func lateCommentsAnswerKeepsTheNewerList() async throws {
            let session = try await sessionOnA()
            let comments = PageComments(pageId: "p1", session: session)
            func list(_ ids: [String]) -> String {
                #"{"data": {"items": [\#(ids.map { #"{"id": "\#($0)"}"# }.joined(separator: ", "))], "meta": {"hasNextPage": false}}}"#
            }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = list(["c1", "c2"]) }
                await comments.load()
                StubURLProtocol.body.withLock { $0 = list(["c1"]) }
            } }
            StubURLProtocol.body.withLock { $0 = list(["c1"]) }
            await comments.load()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(comments.state.value?.map(\.id) == ["c1", "c2"])
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// A posted comment shows at once, with its author (the answer names only the author's ID): each change used to wait
        /// for the whole list, an inline comment's mark with it. A deleted comment goes with its replies.
        @Test func commentChangesShowAtOnce() async throws {
            let session = try await sessionOnA()
            let comments = PageComments(pageId: "p1", session: session)
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"items": [{"id": "c1"}, {"id": "r1", "parentCommentId": "c1"}], "meta": {"hasNextPage": false}}}"#
            }
            await comments.load()
            // From here on the background reloads get no list: what shows is the changes' own answers.
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "c2", "creatorId": "u1"}}"# }
            try await comments.create(text: "Neu", replyTo: nil)
            #expect(comments.state.value?.map(\.id) == ["c1", "r1", "c2"])
            #expect(comments.comment(id: "c2")?.creator?.id == "u1")
            StubURLProtocol.body.withLock { $0 = #"{"success": true}"# }
            try await comments.delete(try #require(comments.comment(id: "c1")))
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(comments.state.value?.map(\.id) == ["c2"])
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// The user changes the query while "Load More" waits, and the new query's results arrive first.
        @Test func lateSearchPageKeepsTheNewQuery() async throws {
            let session = try await sessionOnA()
            let search = SearchModel(query: "a")
            search.session = session
            StubURLProtocol.body.withLock { $0 = Self.results("a1") }
            await search.run()
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                search.query = "b"
                StubURLProtocol.body.withLock { $0 = Self.results("b1") }
                await search.run()
                StubURLProtocol.body.withLock { $0 = Self.results("a2") }
            } }
            await search.loadMore()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(search.results.map(\.id) == ["b1"])
            await removeCaches()
        }

        /// Back from a result, `.task(id: key)` runs the same query again: its results stay as they were, with what
        /// "Load More" added (code review V38: the search started over and the place was lost). Pulling down searches
        /// again.
        @Test func returningKeepsTheResultsUntilAPull() async throws {
            let session = try await sessionOnA()
            let search = SearchModel(query: "a")
            search.session = session
            StubURLProtocol.body.withLock { $0 = Self.results("a1") }
            await search.run()
            StubURLProtocol.body.withLock { $0 = Self.results("a2") }
            await search.loadMore()
            #expect(search.results.map(\.id) == ["a1", "a2"])
            StubURLProtocol.requests.withLock { $0 = [] }
            StubURLProtocol.body.withLock { $0 = Self.results("new") }
            await search.run()
            #expect(search.results.map(\.id) == ["a1", "a2"] && !search.isSearching)
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains { $0.hasSuffix("/api/search") })
            await search.refresh()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(search.results.map(\.id) == ["new"] && !search.isSearching)
            await removeCaches()
        }

        /// A query typed and taken back within the debounce: the cancelled search of the longer one doesn't leave the
        /// spinner on, and the shorter one's results stay.
        @Test func aQueryTakenBackShowsItsResults() async throws {
            let session = try await sessionOnA()
            let clock = TestClock()
            let search = SearchModel(query: "a", clock: clock)
            search.session = session
            StubURLProtocol.body.withLock { $0 = Self.results("a1") }
            let first = Task { await search.run() }
            await clock.advance(by: .milliseconds(300))
            await first.value
            search.query = "ab"
            let typing = Task { await search.run() }
            await clock.advance(by: .milliseconds(100))
            #expect(search.isSearching)
            typing.cancel()
            await typing.value
            search.query = "a"
            await search.run()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(search.results.map(\.id) == ["a1"] && !search.isSearching)
            await removeCaches()
        }

        /// Typing on cancels the running search (`.task(id:)`); that must not show "Search failed".
        @Test func cancelledSearchShowsNoError() async throws {
            let session = try await sessionOnA()
            let search = SearchModel(query: "a")
            search.session = session
            let typing = Task { await search.run() }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { typing.cancel() } }
            await typing.value
            #expect(search.errorMessage == nil)
            await removeCaches()
        }
    }
}
