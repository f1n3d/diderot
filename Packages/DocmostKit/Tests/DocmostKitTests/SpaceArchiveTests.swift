import Foundation
import Testing
@testable import DocmostKit

/// What Docmost 0.98 says of a space beyond the list: its home page and who archived it (`spaces/info`), and whether a
/// favorite's space is archived.
struct SpaceArchiveTests {
    @Test func infoNamesTheHomePageAndWhoArchived() throws {
        let json = #"{"id": "s1", "name": "Demo", "slug": "demo", "homePageId": "p1", "homePage": {"id": "p1", "slugId": "Ab12", "title": "Willkommen", "icon": "👋"}, "archivedAt": "2026-11-20T09:00:00.000Z", "archivedById": "u1", "archivedBy": {"id": "u1", "name": "Alex", "avatarUrl": null}, "membership": {"role": "admin"}}"#
        let space = try JSONDecoding.makeDecoder().decode(Space.self, from: Data(json.utf8))
        #expect(space.homePage?.title == "Willkommen" && space.homePage?.slugId == "Ab12")
        #expect(space.isArchived && space.archivedBy?.name == "Alex" && space.role == .admin)
    }

    /// The list and older servers leave both out; a home page out of the person's reach comes as null.
    @Test func listAndOlderServersHaveNeither() throws {
        let json = #"{"id": "s1", "name": "Demo", "slug": "demo", "homePageId": "p1", "homePage": null}"#
        let space = try JSONDecoding.makeDecoder().decode(Space.self, from: Data(json.utf8))
        #expect(space.homePage == nil && space.archivedBy == nil && !space.isArchived)
    }

    @Test func favoritesNameAnArchivedSpace() throws {
        let json = #"{"id": "f1", "type": "page", "pageId": "p1", "page": {"id": "p1", "title": "Plan"}, "space": {"id": "s1", "name": "Alt", "slug": "alt", "logo": null, "archivedAt": "2026-11-20T09:00:00.000Z"}}"#
        let favorite = try JSONDecoding.makeDecoder().decode(Favorite.self, from: Data(json.utf8))
        #expect(favorite.space?.isArchived == true)
    }
}
