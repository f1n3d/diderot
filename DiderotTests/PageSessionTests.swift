import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// A page's saved copy, its server's page and its engine, with the user and session they belong to.
    @Suite struct Pages: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// The engine's last documents (`LiveDocuments`) belong to a user on a server, and signing out or switching servers
        /// forgets them: keyed by page alone, another account on the device was shown edits the server may not have had.
        @Test func engineDocumentsStayWithTheirUser() async throws {
            let document = PMNode(type: "doc", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Entwurf")])])
            let alice = LiveDocuments.Owner(server: a, userId: "u1")
            func cached(_ owner: LiveDocuments.Owner) -> PMNode? {
                LiveDocuments.document(for: "p", owner: owner, newerThan: nil, serverClockOffset: 0)
            }
            LiveDocuments.store(document, for: "p", owner: alice)
            #expect(cached(LiveDocuments.Owner(server: a, userId: "u2")) == nil)
            #expect(cached(LiveDocuments.Owner(server: b, userId: "u1")) == nil)
            #expect(cached(alice) == document)

            let session = try await sessionOnA()
            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            #expect(cached(alice) == nil)

            // Signed out of the only saved server, so no switch follows that would empty it too.
            let only = SessionStore(keychain: MemorySecretStore())
            try only.save(StoredSession(serverURL: a, token: "a"))
            let alone = AppSession(sessionStore: only, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            await alone.restore()
            try #require(alone.ready?.server.url == a)
            LiveDocuments.store(document, for: "p", owner: alice)
            await alone.signOut()
            #expect(cached(alice) == nil)
            await removeCaches()
        }

        /// The user leaves the page while its editor fetches the collab token: the engine must not connect anyway, or
        /// others would see the user on a page nobody shows.
        @Test func closeDuringEngineStartKeepsTheEngineClosed() async throws {
            let session = try await sessionOnA()
            let engine = WebDocumentEngine(session: session)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"token": "t"}}"# }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { await engine.close() } }
            try await engine.open(pageId: "p1")
            #expect(engine.status == .idle)
            await removeCaches()
        }

        /// A page shows its saved copy first, with the document its unsent changes make and its breadcrumbs; the server's
        /// page is kept under its id and slug id; a page gone for good leaves nothing of itself behind.
        @Test func aPageComesFromItsSavedCopyThenItsServer() async throws {
            let session = try await sessionOnA()
            defer { UnsentChanges.removeAll(server: a) }
            let onA = try #require(session.ready)
            let saved = try JSONDecoder().decode(Page.self, from: Data(#"{"id": "p1", "slugId": "Ab12", "title": "Alt", "spaceId": "s1"}"#.utf8))
            let crumbs = try JSONDecoder().decode([Breadcrumb].self, from: Data(#"[{"id": "p0", "title": "Eltern"}]"#.utf8))
            await onA.cache.write(saved, key: CacheKey.page("Ab12"))
            await onA.cache.write(crumbs, key: CacheKey.breadcrumbs("p1"))
            await onA.cache.write(["Kind"], key: CacheKey.tree(spaceId: "s1", parentPageId: "p1"))
            let unsent = PMNode(type: "doc", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Ungesendet")])])
            try await onA.unsentChanges.write(unsent, key: CacheKey.unsentDocument("p1"))
            let loader = PageLoader(pageId: "Ab12", owner: onA, session: session)

            let shown = try #require(await loader.saved())
            #expect(shown.page.title == "Alt" && shown.unsent == unsent && shown.breadcrumbs == crumbs)

            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p1", "slugId": "Ab12", "title": "Neu", "spaceId": "s1"}}"# }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            let fetched = try await loader.fetch()
            await loader.keep(fetched)
            #expect(await onA.cache.read(Page.self, key: CacheKey.page("p1"))?.title == "Neu")
            #expect(await onA.cache.read(Page.self, key: CacheKey.page("Ab12"))?.title == "Neu")

            await loader.forget(fetched)
            #expect(await onA.cache.read(Page.self, key: CacheKey.page("p1")) == nil)
            #expect(await onA.cache.read(Page.self, key: CacheKey.page("Ab12")) == nil)
            #expect(await onA.cache.read([Breadcrumb].self, key: CacheKey.breadcrumbs("p1")) == nil)
            #expect(await onA.cache.read([String].self, key: CacheKey.tree(spaceId: "s1", parentPageId: "p1")) == nil)
            await removeCaches()
        }

        /// A page deleted for good or no longer shared says so in the app's language; once a switch has replaced the page's
        /// session, it doesn't load from the server now current.
        @Test func aGonePageSaysSo() async throws {
            let session = try await sessionOnA()
            let onA = try #require(session.ready)
            let loader = PageLoader(pageId: "p1", owner: onA, session: session)
            defer {
                StubURLProtocol.status.withLock { $0 = 200 }
                StubURLProtocol.body.withLock { $0 = nil }
            }
            for (status, expected) in [(404, String(localized: "This page doesn't exist anymore.")),
                                       (403, String(localized: "You no longer have access to this page."))] {
                StubURLProtocol.status.withLock { $0 = status }
                StubURLProtocol.body.withLock { $0 = #"{"statusCode": \#(status), "message": "Gone"}"# }
                do {
                    _ = try await loader.fetch()
                    Issue.record("\(status) loaded a page")
                } catch let error as APIError {
                    #expect(error.isGone && error.userMessage == expected)
                }
            }
            StubURLProtocol.status.withLock { $0 = 200 }
            StubURLProtocol.body.withLock { $0 = nil }
            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            await #expect(throws: CancellationError.self) { _ = try await loader.fetch() }
            await removeCaches()
        }
    }
}
