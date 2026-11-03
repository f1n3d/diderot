import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Requests bound to the session they started in: after a switch they don't go out, and a 401 ends only theirs.
    @Suite struct BoundRequests: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// An editor engine still open after a switch to b asks for a fresh collab token for its page on a: it gets none,
        /// where it used to get b's token for a's socket.
        @Test func collabTokenOnlyForTheEnginesOwnSession() async throws {
            let session = try await sessionOnA()
            let owner = try #require(session.ready)
            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            #expect(session.ready?.server.url == b)
            #expect(await WebDocumentEngine.collabToken(session: session, owner: owner) == nil)
            await removeCaches()
        }

        /// A request of a ends with 401 after the switch to b, e.g. because a's token was revoked meanwhile.
        @Test func lateUnauthorizedAnswerKeepsTheSwitch() async throws {
            let session = try await sessionOnA()
            let other = StoredSession(serverURL: b, token: "b")
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/users/me" }
            StubURLProtocol.beforeNextAnswer.withLock {
                $0 = {
                    await session.switchTo(other)
                    StubURLProtocol.status.withLock { $0 = 401 }
                    StubURLProtocol.body.withLock { $0 = #"{"statusCode": 401, "message": "Unauthorized"}"# }
                }
            }
            defer {
                StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
                StubURLProtocol.status.withLock { $0 = 200 }
                StubURLProtocol.body.withLock { $0 = nil }
            }
            _ = try? await session.send(Endpoints.Users.me)
            #expect(session.ready?.server.url == b)
            #expect(try store.loadAccounts().sessions.map(\.serverURL) == [b, a])
            await removeCaches()
        }

        /// The same for a request bound to a's session.
        @Test func lateUnauthorizedAnswerOfABoundRequestKeepsTheSwitch() async throws {
            let session = try await sessionOnA()
            let owner = try #require(session.ready)
            let other = StoredSession(serverURL: b, token: "b")
            _ = try? await session.perform(on: owner) { _ async throws -> Void in
                await session.switchTo(other)
                throw APIError.unauthorized(message: nil)
            }
            #expect(session.ready?.server.url == b)
            #expect(try store.loadAccounts().sessions.map(\.serverURL) == [b, a])
            await removeCaches()
        }

        /// A request bound to a's session doesn't go out once the app has switched to b: a flow's second request, with the
        /// user's note or title, went to b.
        @Test func boundRequestAfterASwitchDoesntGoOut() async throws {
            let session = try await sessionOnA()
            let owner = try #require(session.ready)
            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            StubURLProtocol.requests.withLock { $0 = [] }
            await #expect(throws: SwitchedServer.self) {
                try await session.send(Endpoints.Pages.appendMarkdown(pageId: "p1", "Notiz"), on: owner)
            }
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains { $0.hasSuffix("/api/pages/update") })
            await removeCaches()
        }

        /// The page's edits (`PageEdits`) go to the server the page loaded from and mark its space as changed; once a switch
        /// has replaced that session, nothing goes out: a write says so, a read ends without a word.
        @Test func pageEditsStayWithThePagesServer() async throws {
            let session = try await sessionOnA()
            let onA = try #require(session.ready)
            let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id": "p1", "title": "Alt", "spaceId": "s1"}"#.utf8))
            let changes = ContentChanges()
            let edits = PageEdits(page: page, owner: onA, session: session, changes: changes)
            StubURLProtocol.requests.withLock { $0 = [] }
            StubURLProtocol.body.withLock { $0 = #"{"data": {}}"# }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            try await edits.moveToTrash()
            #expect(StubURLProtocol.requests.withLock { $0 } == ["a.example.com/api/pages/delete"])
            #expect(changes.version == 1 && changes.lastChangedSpaceId == "s1")

            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            StubURLProtocol.requests.withLock { $0 = [] }
            await #expect(throws: SwitchedServer.self) { try await edits.restore() }
            await #expect(throws: CancellationError.self) { _ = try await edits.content(as: "markdown") }
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains { $0.hasSuffix("/api/pages/restore") || $0.hasSuffix("/api/pages/info") })
            #expect(changes.version == 1)
            await removeCaches()
        }

        /// Block views' requests go through the session the page showed with: its 401 ends that session, as the session's
        /// own requests' do. They went out with its bare client, and a 401 there ended nothing.
        @Test func blockViewsRequestThroughTheirSession() async throws {
            let session = try await sessionOnA()
            let context = RenderContext(session: session, pageId: "p")
            StubURLProtocol.status.withLock { $0 = 401 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 401, "message": "Unauthorized"}"# }
            await #expect(throws: APIError.self) { _ = try await context.send(Endpoints.Users.me) }
            StubURLProtocol.status.withLock { $0 = 200 }
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(session.ready == nil, "a's 401 ended it")
            await removeCaches()
        }

        /// What a screen loads for a session that a switch has replaced doesn't go out, and ends as a closing screen's request
        /// does, without an error to show; the session now current stays. A list's later pages went out with the old
        /// client, and their 401 (its server signed out) ended the session now current.
        @Test func aReplacedSessionsLoadEndsWithoutAWord() async throws {
            let session = try await sessionOnA()
            let onA = try #require(session.ready)
            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            try #require(session.ready?.server.url == b)
            StubURLProtocol.requests.withLock { $0 = [] }
            await #expect(throws: CancellationError.self) { _ = try await session.load(Endpoints.Users.me, of: onA) }
            #expect(StubURLProtocol.requests.withLock { $0 }.isEmpty)
            #expect(session.ready?.server.url == b)
            await removeCaches()
        }
    }
}
