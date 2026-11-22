import Foundation
import Testing
@testable import DocmostKit

/// Docmost 0.98's profiles: a person, the spaces both people share and the pages the person created or edited last,
/// decoded from the answers of the 0.98 dev instance.
struct UserProfileTests {
    /// Each request names the person; the lists ask for ten at a time, as the web does, and send a cursor only to go on.
    @Test func requestsNameThePersonAndTheirPlace() throws {
        let info = Endpoints.Users.info(userId: "u1")
        #expect(info.path == "users/info")
        #expect(try body(of: info) == ["userId": "u1"])
        let spaces = Endpoints.Users.spaces(userId: "u1")
        #expect(spaces.path == "users/spaces")
        #expect(try body(of: spaces) == ["userId": "u1", "limit": 10])
        let pages = Endpoints.Users.recentPages(userId: "u1", cursor: "c1")
        #expect(pages.path == "users/recent-pages")
        #expect(try body(of: pages) == ["userId": "u1", "limit": 10, "cursor": "c1"])
    }

    /// A profile comes with the role and whether the person was deactivated or deleted; a deleted person has no email.
    @Test func profilesDecode() throws {
        let active = try decode(UserProfile.self, """
        {"id": "01a169f1-6b44-7b8d-b6a2-305f2265475a", "name": "Alex Morgan", "avatarUrl": null, "email": "alex@docmost.local",
         "role": "member", "deactivatedAt": null, "deletedAt": null}
        """)
        #expect(active.displayName == "Alex Morgan")
        #expect(active.email == "alex@docmost.local")
        #expect(active.role == "member")
        #expect(active.deactivatedAt == nil && active.deletedAt == nil)

        let deleted = try decode(UserProfile.self, """
        {"id": "u2", "name": "", "avatarUrl": "a.png", "email": null, "role": "admin",
         "deactivatedAt": "2026-11-01T10:00:00.000Z", "deletedAt": "2026-11-02T10:00:00.000Z"}
        """)
        #expect(deleted.email == nil)
        #expect(deleted.displayName == "", "neither a name nor an email to show")
        #expect(deleted.deactivatedAt != nil && deleted.deletedAt != nil)
    }

    /// Recent pages carry their space and what the person did; spaces their slug and logo; the cursor comes along while
    /// more follow.
    @Test func listsDecode() throws {
        let pages = try decode(Paginated<UserRecentPage>.self, """
        {"items": [
          {"id": "01a1fba7-6b8b-7e3d-b565-7d5b98946c9e", "slugId": "nW5XvBEMS0", "title": "Editor-Test", "icon": null, "isBase": false,
           "spaceId": "01a11ad8-2d11-7712-9c71-b207a3853ba2",
           "space": {"id": "01a11ad8-2d11-7712-9c71-b207a3853ba2", "name": "Demo", "slug": "demo", "logo": null},
           "activity": "edited", "activityAt": "2026-11-21T01:11:19.958Z"},
          {"id": "p2", "slugId": "Ab12Cd34Ef", "title": null, "icon": "📘", "isBase": true, "spaceId": "s2",
           "space": {"id": "s2", "name": "Projekte", "slug": "projekte", "logo": "logo.png"},
           "activity": "created", "activityAt": "2026-11-20T09:00:00.000Z"}],
         "meta": {"limit": 2, "hasNextPage": true, "hasPrevPage": false,
                  "nextCursor": "YWN0aXZpdHlBdD0yMDI2LTExLTIxVDAxJTNBMTAlM0ExNi44OThaJmlkPTAxYTFmYjI2", "prevCursor": null}}
        """)
        let edited = try #require(pages.items.first)
        #expect(edited.displayTitle == "Editor-Test")
        #expect(edited.space?.displayName == "Demo")
        #expect(edited.wasEdited)
        #expect(edited.activityAt == Date(docmostISO: "2026-11-21T01:11:19.958Z"))
        let created = try #require(pages.items.last)
        #expect(!created.wasEdited)
        #expect(created.displayTitle == PageTitle.untitled)
        #expect(created.isBase == true && created.icon == "📘")
        #expect(pages.meta.hasNextPage && pages.meta.nextCursor?.hasPrefix("YWN0") == true)

        let spaces = try decode(Paginated<UserProfileSpace>.self, """
        {"items": [{"id": "01a11a90-f720-7025-9a8e-dfd2231a5906", "name": "General", "slug": "general", "logo": null}],
         "meta": {"limit": 10, "hasNextPage": false, "hasPrevPage": false, "nextCursor": null, "prevCursor": null}}
        """)
        #expect(spaces.items.map(\.displayName) == ["General"])
        #expect(spaces.items.first?.slug == "general")
        #expect(!spaces.meta.hasNextPage && spaces.meta.nextCursor == nil)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoding.makeDecoder().decode(type, from: Data(json.utf8))
    }
}
