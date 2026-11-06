import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Unsent changes and page titles the server didn't get: kept per server and user, sent once it answers.
    @Suite struct KeptTitles: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// Unsent changes are kept per server and user: signing out keeps them for the next sign-in, removing a saved
        /// server deletes its own.
        /// A title kept for a page of a goes into a's store, also after a switch to b, where it used to be dropped. Forgetting a
        /// sent title removes only that one, not a newer one kept meanwhile.
        @Test func keptTitlesStayWithTheirSession() async throws {
            let session = try await sessionOnA()
            let aStore = try #require(session.ready?.unsentChanges)
            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            await session.keepUnsentTitle("Neu", pageId: "p1", spaceId: nil, in: aStore)
            #expect(try await aStore.read([String: UnsentTitle].self, key: CacheKey.unsentTitles)?["p1"]?.title == "Neu")
            #expect(await session.unsentTitle(pageId: "p1") == nil, "not in b's store")
            // Sent while b is the session: forgotten in a's store, where it was kept, or it went out again later.
            await session.forgetUnsentTitle(pageId: "p1", title: "Neu", in: aStore)
            #expect(try await aStore.read([String: UnsentTitle].self, key: CacheKey.unsentTitles)?["p1"] == nil)

            await session.keepUnsentTitle("Zwei", pageId: "p2", spaceId: nil)
            await session.forgetUnsentTitle(pageId: "p2", title: "Eins")
            #expect(await session.unsentTitle(pageId: "p2") == "Zwei")
            await session.forgetUnsentTitle(pageId: "p2", title: "Zwei")
            #expect(await session.unsentTitle(pageId: "p2") == nil)
            await removeCaches()
        }

        /// Removing a server asks first while changes still wait for it; an emptied title list doesn't count.
        @Test func waitingChangesAreFound() async throws {
            let server = URL(string: "https://unsent-\(UUID().uuidString).example.com")!
            #expect(!UnsentChanges.hasEntries(server: server))
            let store = UnsentChanges.store(server: server, userId: "u1")
            try await store.write([String: UnsentTitle](), key: CacheKey.unsentTitles)
            #expect(!UnsentChanges.hasEntries(server: server), "an emptied title list")
            try await store.writeData(Data([1, 2, 3]), key: CacheKey.unsentChanges("p1"))
            #expect(UnsentChanges.hasEntries(server: server))
            UnsentChanges.removeAll(server: server)
            #expect(!UnsentChanges.hasEntries(server: server))
        }

        @Test func removingAServerDeletesItsUnsentChanges() async throws {
            let session = try await sessionOnA()
            let key = CacheKey.unsentChanges("p")
            try await UnsentChanges.store(server: a, userId: "u1").writeData(Data("a".utf8), key: key)
            try await UnsentChanges.store(server: b, userId: "u1").writeData(Data("b".utf8), key: key)
            #expect(try await UnsentChanges.store(server: a, userId: "u2").readData(key: key) == nil)
            await session.removeAccount(StoredSession(serverURL: b, token: "b"))
            #expect(try await UnsentChanges.store(server: b, userId: "u1").readData(key: key) == nil)
            await session.clearCache()
            await session.signOut()
            #expect(try await UnsentChanges.store(server: a, userId: "u1").readData(key: key) == Data("a".utf8))
            UnsentChanges.removeAll(server: a)
            await removeCaches()
        }

        /// A title the server didn't get waits on the device and goes out with the first try that reaches the server.
        @Test func keptTitleGoesOutOnceTheServerAnswers() async throws {
            let session = try await sessionOnA()
            defer { UnsentChanges.removeAll(server: a) }
            await session.keepUnsentTitle("Neu", pageId: "p1", spaceId: "s1")

            StubURLProtocol.offline.withLock { $0 = true }
            #expect(await session.sendUnsentTitles().spaces.isEmpty)
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(await session.unsentTitle(pageId: "p1") == "Neu")

            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p1", "title": "Neu"}}"# }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            #expect(await session.sendUnsentTitles().spaces == ["s1"])
            #expect(await session.unsentTitle(pageId: "p1") == nil)
            await removeCaches()
        }

        /// A title for a page deleted (or out of reach) meanwhile can never go: it doesn't wait forever, and is named for the
        /// notice (it used to go only to the log).
        @Test func keptTitleOfAGonePageIsDropped() async throws {
            let session = try await sessionOnA()
            defer { UnsentChanges.removeAll(server: a) }
            await session.keepUnsentTitle("Neu", pageId: "p1", spaceId: "s1")

            StubURLProtocol.status.withLock { $0 = 404 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 404, "message": "Page not found"}"# }
            defer {
                StubURLProtocol.status.withLock { $0 = 200 }
                StubURLProtocol.body.withLock { $0 = nil }
            }
            let sent = await session.sendUnsentTitles()
            #expect(sent.spaces.isEmpty)
            #expect(sent.dropped.map(\.name) == ["Neu"] && sent.dropped.map(\.reason) == ["Page not found"])
            #expect(await session.unsentTitle(pageId: "p1") == nil)
            await removeCaches()
        }

        /// The title field (`PageTitleEdit`): a title the server doesn't get stays on the device and shows as not sent yet;
        /// one it gets is forgotten, and the page loads again; one for a page gone for good is dropped, saying why.
        @Test(.timeLimit(.minutes(1))) func aTypedTitleIsKeptUntilTheServerHasIt() async throws {
            let session = try await sessionOnA()
            defer { UnsentChanges.removeAll(server: a) }
            let onA = try #require(session.ready)
            let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id": "p1", "title": "Alt", "spaceId": "s1"}"#.utf8))
            let edit = PageTitleEdit()
            var reports: [String] = []
            var loads = 0
            func commit(_ text: String) async {
                edit.text = text
                await edit.commit(page, in: onA, session: session, changes: ContentChanges(), sent: { loads += 1 }) { reports.append($0) }?.value
            }

            StubURLProtocol.offline.withLock { $0 = true }
            await commit("Neu")
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(edit.unsent == "Neu" && reports.count == 1)
            #expect(await session.unsentTitle(pageId: "p1") == "Neu")

            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p1", "title": "Neuer"}}"# }
            await commit("Neuer")
            for _ in 0..<100 where loads == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(edit.unsent == nil && loads == 1 && reports.count == 1)
            #expect(await session.unsentTitle(pageId: "p1") == nil)

            StubURLProtocol.status.withLock { $0 = 404 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 404, "message": "Page not found"}"# }
            defer {
                StubURLProtocol.status.withLock { $0 = 200 }
                StubURLProtocol.body.withLock { $0 = nil }
            }
            await commit("Weg")
            #expect(reports.last == "Page not found")
            #expect(await session.unsentTitle(pageId: "p1") == nil)
            await removeCaches()
        }

        /// A title typed on a page whose session a switch replaced waits for that server's next sign-in: it doesn't go to
        /// the server now current.
        @Test func aTypedTitleOfAReplacedSessionWaitsForItsServer() async throws {
            let session = try await sessionOnA()
            defer { UnsentChanges.removeAll(server: a) }
            let onA = try #require(session.ready)
            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id": "p1", "title": "Alt"}"#.utf8))
            let edit = PageTitleEdit()
            edit.text = "Neu"
            var reports: [String] = []
            StubURLProtocol.requests.withLock { $0 = [] }
            await edit.commit(page, in: onA, session: session, changes: ContentChanges(), sent: {}) { reports.append($0) }?.value
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains { $0.hasSuffix("/api/pages/update") })
            #expect(reports.isEmpty, "it waits without a word, like the text")
            #expect(try await onA.unsentChanges.read([String: UnsentTitle].self, key: CacheKey.unsentTitles)?["p1"]?.title == "Neu")
            await removeCaches()
        }

        /// Titles kept at the same moment (two windows going to the background) all stay: each keep read the list, waited and
        /// wrote it back, so one could drop another's.
        @Test func titlesKeptAtOnceAllStay() async throws {
            let session = try await sessionOnA()
            defer { UnsentChanges.removeAll(server: a) }
            // Started together, they take turns at every await.
            let keeps = (0..<20).map { index in Task { await session.keepUnsentTitle("T\(index)", pageId: "p\(index)", spaceId: nil) } }
            for keep in keeps { #expect(await keep.value) }
            let kept = try await session.ready?.unsentChanges.read([String: UnsentTitle].self, key: CacheKey.unsentTitles)
            #expect(kept?.count == 20)
            await removeCaches()
        }

        /// A list of kept titles the app can't read (a damaged file, or one of a later version) isn't replaced: it read as
        /// empty, and the next title kept dropped every one in it.
        @Test func unreadableKeptTitlesStay() async throws {
            let session = try await sessionOnA()
            defer { UnsentChanges.removeAll(server: a) }
            let store = try #require(session.ready?.unsentChanges)
            try await store.write(["p1": "not a title"], key: CacheKey.unsentTitles)
            #expect(await session.keepUnsentTitle("Neu", pageId: "p2", spaceId: nil) == false)
            #expect(await session.sendUnsentTitles().spaces.isEmpty)
            #expect(try await store.read([String: String].self, key: CacheKey.unsentTitles) == ["p1": "not a title"])
            await removeCaches()
        }
    }
}
