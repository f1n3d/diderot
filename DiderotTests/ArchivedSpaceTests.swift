import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Docmost 0.98 archives spaces. The app lists them too, for the role and name a page there needs; the Spaces tab shows
/// them after the active ones, and a page isn't offered one to move or copy to, as on the web.
struct ArchivedSpaceTests {
    @Test func spacesTabShowsArchivedOnesLast() throws {
        let spaces = try [space("a"), space("b", archived: true), space("c"), space("d", archived: true)]
        #expect(SpacesStore.activeFirst(spaces).map(\.id) == ["a", "c", "b", "d"])
        #expect(SpacesStore.activeFirst([]).isEmpty)
    }

    @Test func archivedSpacesArentOfferedToMoveOrCopyTo() throws {
        let spaces = try [space("a"), space("b", archived: true), space("c")]
        #expect(SpacePickerSheet.candidates(in: spaces, excluding: "a").map(\.id) == ["c"])
        #expect(SpacePickerSheet.candidates(in: spaces, excluding: nil).map(\.id) == ["a", "c"])
    }

    /// The models have no public initializers; build them as the server sends them. A plain JSONDecoder reads dates as
    /// seconds since 2001.
    private func space(_ id: String, archived: Bool = false) throws -> Space {
        let json: JSONValue = ["id": .string(id), "name": .string(id.uppercased()), "slug": .string(id), "archivedAt": archived ? 0 : nil]
        return try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(json))
    }
}
