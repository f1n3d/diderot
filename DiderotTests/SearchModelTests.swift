import Foundation
import Testing
@testable import Diderot

struct SearchModelTests {
    /// A query shows the spinner from its first key (code review R39): during the debounce the results said "No
    /// Results" for a query not sent yet. A cleared query shows neither.
    @Test func searchIsPendingFromTheFirstKey() async throws {
        let search = SearchModel(query: "a")
        let typing = Task { await search.run() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(search.isSearching)
        await typing.value
        #expect(!search.isSearching)
        search.query = ""
        await search.run()
        #expect(!search.isSearching)
    }
}
