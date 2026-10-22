import Foundation
import Testing
@testable import DocmostKit

struct ActivityFixtureTests {
    @Test func searchResultsWithHighlights() throws {
        let response = try TestSupport.decodeFixture(SearchResponse.self, "search")
        #expect(!response.items.isEmpty)
        let first = try #require(response.items.first)
        #expect(first.displayTitle.contains("Handbuch"))
        #expect(first.space?.slug == "demo")
        #expect(first.icon == "📘")
        let runs = first.highlightRuns
        #expect(runs.first == HighlightRun(text: "Handbuch", isMatch: true))
        #expect(runs.contains { !$0.isMatch })

        let titleOnly = try TestSupport.decodeFixture(SearchResponse.self, "search-title-only")
        #expect(titleOnly.items.count == 3)
    }

    @Test func highlightParsing() {
        #expect(HighlightRun.parse("") == [])
        #expect(HighlightRun.parse("plain") == [HighlightRun(text: "plain", isMatch: false)])
        #expect(HighlightRun.parse("a <b>b</b> c <b>d</b>") == [
            HighlightRun(text: "a ", isMatch: false), HighlightRun(text: "b", isMatch: true),
            HighlightRun(text: " c ", isMatch: false), HighlightRun(text: "d", isMatch: true),
        ])
        #expect(HighlightRun.parse("<b>unclosed") == [HighlightRun(text: "unclosed", isMatch: true)])
    }

    @Test func suggestions() throws {
        let suggestions = try TestSupport.decodeFixture(SearchSuggestions.self, "search-suggest")
        #expect(suggestions.users?.first?.name == "Dev Admin")
        #expect(suggestions.pages != nil)
    }

    @Test func favoritesCarryPageOrSpace() throws {
        let favorites = try TestSupport.decodeFixture(Paginated<Favorite>.self, "favorites")
        #expect(favorites.items.count == 2)
        let space = try #require(favorites.items.first { $0.favoriteType == .space })
        #expect(space.space?.name == "Demo")
        let page = try #require(favorites.items.first { $0.favoriteType == .page })
        #expect(page.page?.displayTitle == "Handbuch – Abschnitt 1.1")
        #expect(page.page?.slugId != nil)

        let ids = try TestSupport.decodeFixture(FavoriteIds.self, "favorite-ids")
        #expect(ids.items == [page.pageId])
    }

    @Test func notificationsDecode() throws {
        let notifications = try TestSupport.decodeFixture(Paginated<ActivityNotification>.self, "notifications")
        #expect(notifications.items.isEmpty)
        let unread = try TestSupport.decodeFixture(UnreadCount.self, "notifications-unread")
        #expect(unread.count == 0)

        let json = """
        {"id":"n1","type":"comment.user_mention","actorId":"u1","pageId":"p1","readAt":null,"createdAt":"2026-10-08T10:00:00.000Z",
         "actor":{"id":"u1","name":"Jane","avatarUrl":null},"page":{"id":"p1","title":"Roadmap","slugId":"abc","icon":"🗺️"},"space":{"id":"s1","name":"Demo","slug":"demo"}}
        """
        let notification = try JSONDecoding.makeDecoder().decode(ActivityNotification.self, from: Data(json.utf8))
        #expect(notification.isUnread)
        #expect(notification.page?.displayTitle == "Roadmap")
    }
}
