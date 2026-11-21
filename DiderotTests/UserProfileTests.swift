import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Profiles (Docmost 0.98): the profile, then its lists with "Load More"; "Profile not found" for a person who
    /// isn't there; lists that failed load again; a "Load More" that a refresh overtook drops its page.
    @Suite struct Profiles: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// Alex Morgan's id on the 0.98 dev instance.
        static let alex = "01a169f1-6b44-7b8d-b6a2-305f2265475a"

        /// The profile shows, then both lists with their first page; "Load More" adds the next one, after which no more
        /// follow.
        @Test func profileShowsWithItsLists() async throws {
            let session = try await sessionOnA()
            defer { withExtendedLifetime(session) {} }  // the model holds it unowned
            let model = UserProfileModel(userId: Self.alex, session: session)
            StubURLProtocol.body.withLock { $0 = Self.answer(item: "i1", next: "c1") }
            StubURLProtocol.requests.withLock { $0 = [] }
            await model.load()
            #expect(model.profile.value?.displayName == "Alex Morgan")
            #expect(model.profile.value?.email == "alex@docmost.local")
            #expect(Set(requests()) == ["users/info", "users/recent-pages", "users/spaces"])
            #expect(model.recentPages.state.value?.map(\.id) == ["i1"] && model.recentPages.hasMore)
            #expect(model.recentPages.state.value?.first?.wasEdited == true)
            #expect(model.spaces.state.value?.map(\.displayName) == ["Demo"])

            StubURLProtocol.body.withLock { $0 = Self.answer(item: "i2", next: nil) }
            await model.loadMore(model.recentPages)
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.recentPages.state.value?.map(\.id) == ["i1", "i2"] && !model.recentPages.hasMore)
            #expect(!model.isNotFound && !model.isSelf && model.toast == nil)
            await removeCaches()
        }

        /// Docmost's 404 for a person it doesn't know (also a deactivated or deleted one, for someone who doesn't manage
        /// members) shows "Profile not found", and the lists aren't asked for; an id that is no UUID isn't asked for at
        /// all, as on the web. Another failure is no "not found": it offers "Try Again".
        @Test func missingPersonIsNotFound() async throws {
            let session = try await sessionOnA()
            defer { withExtendedLifetime(session) {} }
            StubURLProtocol.status.withLock { $0 = 404 }
            StubURLProtocol.body.withLock { $0 = #"{"message": "User not found", "error": "Not Found", "statusCode": 404}"# }
            StubURLProtocol.requests.withLock { $0 = [] }
            let missing = UserProfileModel(userId: Self.alex, session: session)
            await missing.load()
            StubURLProtocol.status.withLock { $0 = 200 }
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(missing.isNotFound)
            #expect(requests() == ["users/info"])
            #expect(missing.recentPages.state.value == nil && missing.spaces.state.value == nil)

            StubURLProtocol.requests.withLock { $0 = [] }
            let malformed = UserProfileModel(userId: "u1", session: session)
            await malformed.load()
            #expect(malformed.isNotFound && requests().isEmpty)

            StubURLProtocol.offline.withLock { $0 = true }
            let offline = UserProfileModel(userId: Self.alex, session: session)
            await offline.load()
            StubURLProtocol.offline.withLock { $0 = false }
            guard case .failed = offline.profile else {
                Issue.record("No error offline: \(offline.profile)")
                return
            }
            #expect(!offline.isNotFound)
            await removeCaches()
        }

        /// Lists whose first page failed load again when the profile shows again (back from a page opened there). The
        /// own profile loads its lists without asking for the profile.
        @Test func failedListsLoadAgain() async throws {
            let session = try await sessionOnA()
            defer { withExtendedLifetime(session) {} }
            // The stub's user.
            let own = UserProfileModel(userId: "u1", session: session)
            #expect(own.isSelf)
            StubURLProtocol.offline.withLock { $0 = true }
            await own.loadListsIfNeeded()
            StubURLProtocol.offline.withLock { $0 = false }
            guard case .failed = own.recentPages.state, case .failed = own.spaces.state else {
                Issue.record("Lists didn't fail offline: \(own.recentPages.state), \(own.spaces.state)")
                return
            }
            StubURLProtocol.body.withLock { $0 = Self.answer(item: "i1", next: nil) }
            StubURLProtocol.requests.withLock { $0 = [] }
            await own.loadListsIfNeeded()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(own.recentPages.state.value?.map(\.id) == ["i1"] && own.spaces.state.value?.map(\.id) == ["i1"])
            #expect(Set(requests()) == ["users/recent-pages", "users/spaces"])
            #expect(own.profile.value == nil)
            await removeCaches()
        }

        /// A refresh that answers while "Load More" waits wins: the page "Load More" brings continued the list from
        /// before, and is dropped instead of landing after the refreshed first page.
        @Test func loadMoreOvertakenByARefreshIsDropped() async throws {
            let session = try await sessionOnA()
            defer { withExtendedLifetime(session) {} }
            let model = UserProfileModel(userId: Self.alex, session: session)
            StubURLProtocol.body.withLock { $0 = Self.answer(item: "i1", next: "c1") }
            await model.load()
            try #require(model.recentPages.cursor == "c1")
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/users/recent-pages" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = Self.answer(item: "n1", next: "c2") }
                await model.reload(model.recentPages)
                StubURLProtocol.body.withLock { $0 = Self.answer(item: "i2", next: nil) }
            } }
            await model.loadMore(model.recentPages)
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = nil }
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.recentPages.state.value?.map(\.id) == ["n1"])
            #expect(model.recentPages.cursor == "c2" && !model.recentPages.isLoadingMore)
            await removeCaches()
        }

        // MARK: Helpers

        /// One answer for all three requests, as the stub gives each the same: the profile reads Alex's fields, both
        /// lists `items` and `meta`, the one item as a recent page or a space.
        private static func answer(item: String, next cursor: String?) -> String {
            let meta = cursor.map { #"{"hasNextPage": true, "nextCursor": "\#($0)"}"# } ?? #"{"hasNextPage": false}"#
            return #"""
            {"data": {"id": "\#(alex)", "name": "Alex Morgan", "avatarUrl": null, "email": "alex@docmost.local", "role": "member",
              "deactivatedAt": null, "deletedAt": null,
              "items": [{"id": "\#(item)", "slugId": "s\#(item)", "title": "Seite \#(item)", "name": "Demo", "slug": "demo",
                         "activity": "edited", "activityAt": "2026-11-21T01:11:19.958Z"}],
              "meta": \#(meta)}}
            """#
        }

        /// The profile requests since the list was emptied, by their path under `/api/`.
        private func requests() -> [String] {
            StubURLProtocol.requests.withLock { $0 }.compactMap { request in
                request.hasPrefix("a.example.com/api/users/") && request != "a.example.com/api/users/me"
                    ? String(request.dropFirst("a.example.com/api/".count)) : nil
            }
        }
    }
}
