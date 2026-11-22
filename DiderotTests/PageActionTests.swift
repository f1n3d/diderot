import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The page actions of the tree's and the page's menus (`PageActionRunner`).
    @Suite struct PageActions: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// A duplicate the server got but answered later than the app waits: the server goes on and makes the copy, so
        /// the tree reloads to show it and the toast says it is still coming. The app said "The request timed out." and
        /// showed no copy, and a second Duplicate made a second one.
        @Test func aDuplicateThatTimesOutStillShowsInTheTree() async throws {
            let session = try await sessionOnA()
            let changes = ContentChanges()
            let runner = PageActionRunner(session: session, changes: changes)
            let page = PageRef(id: "p1", slugId: "plan", title: "Plan", spaceId: "s1")
            StubURLProtocol.failure.withLock { $0 = URLError(.timedOut).afterSending() }
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

        /// A gateway in front of the server that gave up waiting for its answer (nginx's 504 after 60 s, Cloudflare's 524
        /// after 100 s) leaves the server making the copy, as the app's own timeout does. The app said "Server error
        /// (504)." and showed no copy, and a second Duplicate made a second one.
        @Test(arguments: [504, 524]) func aDuplicateAGatewayGaveUpOnStillShowsInTheTree(status: Int) async throws {
            let session = try await sessionOnA()
            let changes = ContentChanges()
            let runner = PageActionRunner(session: session, changes: changes)
            StubURLProtocol.status.withLock { $0 = status }
            StubURLProtocol.body.withLock { $0 = "<html><body><h1>504 Gateway Time-out</h1></body></html>" }
            defer {
                StubURLProtocol.status.withLock { $0 = 200 }
                StubURLProtocol.body.withLock { $0 = nil }
            }

            await runner.duplicate(PageRef(id: "p1", spaceId: "s1"))
            #expect(changes.version == 1 && changes.lastChangedSpaceId == "s1")
            #expect(runner.toast == String(localized: "The server is still making the copy. It may take a while to appear."))
            await removeCaches()
        }

        /// Any other failure leaves the tree as it is and says why. A timeout before the request got out is one: the
        /// server can't be reached (behind a VPN that is off), never got it and makes no copy, and the toast said the
        /// copy was still coming.
        @Test(arguments: [URLError.Code.cannotConnectToHost, .timedOut]) func aDuplicateThatFailsOtherwiseSaysWhy(code: URLError.Code) async throws {
            let session = try await sessionOnA()
            let changes = ContentChanges()
            let runner = PageActionRunner(session: session, changes: changes)
            StubURLProtocol.failure.withLock { $0 = URLError(code) }
            defer { StubURLProtocol.failure.withLock { $0 = nil } }

            await runner.duplicate(PageRef(id: "p1", spaceId: "s1"))
            #expect(changes.version == 0)
            #expect(runner.toast == APIError.network(URLError(code)).userMessage)
            await removeCaches()
        }

        /// A page is duplicated once at a time, and the toast says when it starts: the server answers once it has copied
        /// the whole tree, which can take minutes. Nothing showed meanwhile, and a second Duplicate made a second copy.
        /// Copy to Space sends the same request, so it waits for the duplicate too.
        @Test func aPageIsDuplicatedOnceAtATime() async throws {
            let session = try await sessionOnA()
            let runner = PageActionRunner(session: session, changes: ContentChanges())
            let page = PageRef(id: "p1", slugId: "plan", title: "Plan", spaceId: "s1")
            let (answer, release) = AsyncStream.makeStream(of: Void.self)
            StubURLProtocol.requests.withLock { $0 = [] }
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p2", "title": "Copy of Plan", "spaceId": "s1"}}"# }
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/pages/duplicate" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { for await _ in answer {} } }
            defer {
                StubURLProtocol.body.withLock { $0 = nil }
                StubURLProtocol.beforeNextAnswer.withLock { $0 = nil }
                StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
            }
            func duplicates() -> Int {
                StubURLProtocol.requests.withLock { $0 }.filter { $0 == "a.example.com/api/pages/duplicate" }.count
            }

            let first = Task { await runner.duplicate(page) }
            while duplicates() == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(runner.toast == String(localized: "Duplicating page…"))
            #expect(runner.isCopying(page), "the menu turns Duplicate and Copy to Space off")
            await runner.duplicate(page)
            await runner.duplicate(page, toSpaceId: "s2")
            #expect(duplicates() == 1)

            release.finish()
            await first.value
            #expect(duplicates() == 1)
            #expect(!runner.isCopying(page))
            #expect(runner.toast == String(localized: "Page duplicated"))
            await removeCaches()
        }
    }
}
