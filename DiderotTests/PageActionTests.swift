import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The page actions of the tree's and the page's menus (`PageActionRunner`).
    @Suite struct PageActions: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// A duplicate the server answers later than the app waits: the server goes on and makes the copy, so the tree
        /// reloads to show it and the toast says it is still coming. The app said "The request timed out." and showed
        /// no copy, and a second Duplicate made a second one.
        @Test func aDuplicateThatTimesOutStillShowsInTheTree() async throws {
            let session = try await sessionOnA()
            let changes = ContentChanges()
            let runner = PageActionRunner(session: session, changes: changes)
            let page = PageRef(id: "p1", slugId: "plan", title: "Plan", spaceId: "s1")
            StubURLProtocol.failure.withLock { $0 = .timedOut }
            defer { StubURLProtocol.failure.withLock { $0 = nil } }

            await runner.duplicate(page)
            #expect(changes.version == 1 && changes.lastChangedSpaceId == "s1")
            #expect(runner.toast == String(localized: "The server is still making the copy. It may take a while to appear."))

            runner.toast = nil
            await runner.duplicate(page, toSpaceId: "s2")
            #expect(changes.version == 2 && changes.lastChangedSpaceId == "s2", "a copy to another space reloads that one")
            #expect(runner.toast == String(localized: "The server is still making the copy. It may take a while to appear."))
            await removeCaches()
        }

        /// Any other failure leaves the tree as it is and says why.
        @Test func aDuplicateThatFailsOtherwiseSaysWhy() async throws {
            let session = try await sessionOnA()
            let changes = ContentChanges()
            let runner = PageActionRunner(session: session, changes: changes)
            StubURLProtocol.failure.withLock { $0 = .cannotConnectToHost }
            defer { StubURLProtocol.failure.withLock { $0 = nil } }

            await runner.duplicate(PageRef(id: "p1", spaceId: "s1"))
            #expect(changes.version == 0)
            #expect(runner.toast == APIError.network(URLError(.cannotConnectToHost)).userMessage)
            await removeCaches()
        }
    }
}
