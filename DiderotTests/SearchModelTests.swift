import Foundation
import Testing
@testable import Diderot

struct SearchModelTests {
    /// A query shows the spinner from its first key (code review R39): during the debounce the results said "No
    /// Results" for a query not sent yet. A cleared query shows neither. On a clock of its own: checked after 50 ms of
    /// real time, the spinner's check passed only while the main actor didn't spend the debounce's 300 ms elsewhere.
    @Test func searchIsPendingFromTheFirstKey() async throws {
        let clock = TestClock()
        let search = SearchModel(query: "a", clock: clock)
        let typing = Task { await search.run() }
        await clock.advance(by: .milliseconds(299))
        #expect(search.isSearching)
        await clock.advance(by: .milliseconds(1))
        await typing.value
        #expect(!search.isSearching)
        search.query = ""
        await search.run()
        #expect(!search.isSearching)
    }
}
