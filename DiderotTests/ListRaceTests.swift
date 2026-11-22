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

        /// The poll's count is on its way when the user marks notifications read. The count the server worked out
        /// before the mark arrives after it: it used to put the old number back on the bell until the next poll. The
        /// count a Direct list asks for after loading still applies.
        @Test func lateUnreadCountKeepsTheMark() async throws {
            let session = try await sessionOnA()
            let notifications = NotificationsStore(session: session)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [{"id": "n1", "type": "page.updated"}], "meta": {"hasNextPage": false}}}"# }
            await notifications.loadList()
            let notification = try #require(notifications.listState.value?.first)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"count": 7}}"# }
            await notifications.refreshUnreadCount()
            #expect(notifications.unreadCount == 7)
            let count = "a.example.com/api/notifications/unread-count"
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = count }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in await notifications.markRead(notification) } }
            await notifications.refreshUnreadCount()
            #expect(notifications.unreadCount == 6, "one marked read")
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = count }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in await notifications.markAllRead() } }
            await notifications.refreshUnreadCount()
            #expect(notifications.unreadCount == 0, "all marked read")
            notifications.filter = .direct
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [], "meta": {"hasNextPage": false}}}"# }
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = count }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { StubURLProtocol.body.withLock { $0 = #"{"data": {"count": 2}}"# } } }
            await notifications.loadList()
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(notifications.unreadCount == 2, "a list's own count")
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

        /// The user stars one page and unstars another while the favorite ids are on their way, and the answer, from
        /// before both, arrives last: both changes stay, and so does the rest of the answer. The answer used to undo them
        /// until the Favorites tab loaded.
        @Test func starsChangedWhileTheIdsLoadStay() async throws {
            let session = try await sessionOnA()
            let favorites = FavoritesStore(session: session)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": ["p1"]}}"# }
            await favorites.loadIds()
            try #require(favorites.isFavorite(pageId: "p1"))
            // The toggles' answers get this body too, which they ignore.
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": ["p1", "p3"]}}"# }
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/favorites/ids" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                await favorites.togglePage("p2")
                await favorites.togglePage("p1")
            } }
            await favorites.loadIds()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(favorites.isFavorite(pageId: "p2") && !favorites.isFavorite(pageId: "p1"))
            #expect(favorites.isFavorite(pageId: "p3"), "the rest of the answer counts")
            #expect(favorites.toast == nil)
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// A star whose request is still on its way when the ids load starts stays too: the load began after the tap, but
        /// its answer can still be from before the server took the star.
        @Test func aStarOnItsWayWhenTheIdsLoadStartsStays() async throws {
            let session = try await sessionOnA()
            let favorites = FavoritesStore(session: session)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": ["p1"]}}"# }
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/favorites/add" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            // While the star's request waits for its answer, the ids load and answer without it.
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in await favorites.loadIds() } }
            await favorites.togglePage("p2")
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(favorites.isFavorite(pageId: "p2"))
            #expect(favorites.isFavorite(pageId: "p1"), "the rest of the answer counts")
            #expect(favorites.toast == nil)
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// The Favorites tab opens while the ids are on their way and shows the list cached at an earlier launch; then
        /// the list's own request fails. The ids answer, newer than the cache, decides the stars: it used to be dropped
        /// as older, leaving the cache's, which can be days old. Spaces, as their answer is taken after the pages':
        /// after the cached list, whichever of the two requests waits.
        @Test func aCachedListDoesntOutweighTheIdsOnTheirWay() async throws {
            let session = try await sessionOnA()
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [{"id": "f1", "type": "space", "spaceId": "s1"}], "meta": {"hasNextPage": false}}}"# }
            await FavoritesStore(session: session).loadList()
            let favorites = FavoritesStore(session: session)
            // Since then s1 was unstarred and s2 starred on the web. The list's request gets this body too, which it
            // can't read.
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": ["s2"]}}"# }
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/favorites/ids" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in await favorites.loadList() } }
            await favorites.loadIds()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(favorites.listState.value?.map(\.id) == ["f1"], "the cached list shows")
            #expect(favorites.isFavorite(spaceId: "s2") && !favorites.isFavorite(spaceId: "s1"))
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

        /// The sheet closes while a comment goes out and opens again with the same draft: Send there posted it a second
        /// time, as the flag that blocks it lived in the closed sheet. Text the draft gets meanwhile stays: the answer
        /// emptied it, and only what was there at Send went out.
        @Test func aCommentGoesOutOnce() async throws {
            let session = try await sessionOnA()
            let comments = PageComments(pageId: "p1", session: session)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [], "meta": {"hasNextPage": false}}}"# }
            await comments.load()
            comments.draft = "Looks good "
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "c1", "creatorId": "u1"}}"# }
            StubURLProtocol.requests.withLock { $0 = [] }
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/comments/create" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                #expect(comments.isSending, "the sheet opened again shows the send")
                #expect(await comments.send() == nil, "and Send there posts nothing")
                comments.draft = "Looks good!"
            } }
            #expect(await comments.send() == .new(thread: "c1"))
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = nil }
            #expect(StubURLProtocol.requests.withLock { $0 }.filter { $0.hasSuffix("/api/comments/create") }.count == 1)
            #expect(comments.draft == "Looks good!" && !comments.isSending)
            #expect(comments.state.value?.map(\.id) == ["c1"])
            // A draft left as it was starts over.
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "c2", "creatorId": "u1"}}"# }
            #expect(await comments.send() == .new(thread: "c2"))
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(comments.draft.isEmpty && comments.composing == .new)
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

        /// With page permissions (a license feature), Docmost leaves out the pages the user may not open only after
        /// taking 25 matches: a page of 24 isn't the last, and the next starts at the 26th match, not after the 24
        /// shown. A result that moved to the next page between the two shows once; an empty page ends the results.
        @Test func aPageShortOfARestrictedPageHasMore() async throws {
            let permissions = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "enterprise", "features": ["page:permissions"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(permissions, key: CacheKey.entitlements)
            let session = try await sessionOnA()
            let search = SearchModel(query: "a")
            search.session = session
            let first = (1...24).map { "a\($0)" }
            StubURLProtocol.body.withLock { $0 = Self.results(first) }
            await search.run()
            #expect(search.results.map(\.id) == first && search.hasMore)
            StubURLProtocol.body.withLock { $0 = Self.results(["a24", "a25"]) }
            await search.loadMore()
            #expect(try searchOffset() == 25)
            #expect(search.results.map(\.id) == first + ["a25"] && search.hasMore)
            StubURLProtocol.body.withLock { $0 = Self.results([]) }
            await search.loadMore()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(try searchOffset() == 50)
            #expect(search.results.map(\.id) == first + ["a25"] && !search.hasMore)
            await removeCaches()
        }

        /// Without page permissions the server leaves nothing out: a short page is the last, and no "Load More"
        /// follows it that finds nothing. A full page has more.
        @Test func aShortPageEndsTheResults() async throws {
            let session = try await sessionOnA()
            let search = SearchModel(query: "a")
            search.session = session
            StubURLProtocol.body.withLock { $0 = Self.results((1...25).map { "a\($0)" }) }
            await search.run()
            #expect(search.results.count == 25 && search.hasMore)
            StubURLProtocol.body.withLock { $0 = Self.results(["a26"]) }
            await search.loadMore()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(try searchOffset() == 25)
            #expect(search.results.count == 26 && !search.hasMore)
            await removeCaches()
        }

        /// Where the last search asked to start.
        private func searchOffset() throws -> JSONValue? {
            let sent = try #require(StubURLProtocol.bodies.withLock { $0["a.example.com/api/search"] })
            return try JSONDecoder().decode([String: JSONValue].self, from: sent)["offset"]
        }
    }
}
