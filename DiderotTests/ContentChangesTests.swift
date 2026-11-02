import Testing
@testable import Diderot

/// Titles kept offline go out together once the app is back online (code review R27): views see one change for all of
/// them, so several spaces count as all, and every open space reloads, not only the last one's.
struct ContentChangesTests {
    @Test func severalSpacesAtOnceReloadAll() {
        let changes = ContentChanges()
        changes.pagesChanged(in: ["a", "a"])
        #expect(changes.lastChangedSpaceId == "a" && changes.version == 1)
        changes.pagesChanged(in: ["a", "b"])
        #expect(changes.lastChangedSpaceId == nil && changes.version == 2)
        changes.pagesChanged(in: [])
        #expect(changes.version == 2)
    }
}
