import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Verified and approved pages (license feature `page:verification`, Docmost 0.98): any edit takes the verification
    /// back, so such a page opens read-only and asks first, as the web does; the engine waits for the status, whose first
    /// sync would send unsent changes, and a title kept for later waits for "Edit".
    @Suite struct VerifiedPages: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// A lock makes the page read-only, after the reasons that already held; an unknown status waits, one the server
        /// didn't say pauses editing, no lock edits.
        @Test func lockedPagesOpenReadOnly() throws {
            let editable = try Self.page(canEdit: true)
            let readable = try Self.page(canEdit: false)
            func reason(_ verification: PageLoader.Verification, of page: Page? = nil, offline: Bool = false, newer: String? = nil)
                -> DocumentModel.ReadOnlyReason? {
                PageLoader.readOnlyReason(of: page ?? editable, isOffline: offline, newerServerVersion: newer, verification: verification)
            }
            #expect(reason(.open) == nil)
            #expect(reason(.locked(.approved)) == .verified(.approved))
            #expect(reason(.unknown) == .checkingVerification)
            #expect(reason(.unavailable) == .verificationUnavailable)
            #expect(reason(.unavailable, offline: true) == .offline)
            #expect(reason(.locked(.verified), of: readable) == .noPermission)
            #expect(reason(.locked(.verified), offline: true) == .offline)
            #expect(reason(.unknown, newer: "0.99.0") == .newerServer("0.99.0"))
        }

        /// With the license feature the status comes from the server, at each opening; a server without enterprise code
        /// (404) has none. One that fails otherwise gives no answer, not one kept from before: as on the web, the page then
        /// waits for one before it edits (`PageLoader.Verification.unavailable`).
        @Test func statusComesFromTheServer() async throws {
            let (session, loader) = try await licensed(["page:verification"])
            defer { resetStub() }
            let page = try Self.page(canEdit: true)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"status": "in_approval", "type": "qms"}}"# }
            #expect(await loader.verification(of: page)?.lock == .inApproval)

            StubURLProtocol.status.withLock { $0 = 500 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 500, "message": "Internal server error"}"# }
            #expect(await loader.verification(of: page) == nil)

            StubURLProtocol.status.withLock { $0 = 404 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 404, "message": "Cannot POST /api/pages/verification-info"}"# }
            #expect(await loader.verification(of: page)?.status == "none")
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// A title kept while the server was out of reach takes a verification back as any rename does: a verified page's
        /// waits for "Edit" on the page (`consented`, with the lock the person edits through), and goes where the page has
        /// no lock.
        @Test func keptTitleOfAVerifiedPageWaitsForEdit() async throws {
            let (session, _) = try await licensed(["page:verification"])
            defer {
                resetStub()
                UnsentChanges.removeAll(server: a)
            }
            await session.keepUnsentTitle("Neu", pageId: "p1", spaceId: "s1")
            // One answer for the verification and the rename alike.
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p1", "title": "Neu", "status": "verified"}}"# }
            StubURLProtocol.requests.withLock { $0 = [] }
            #expect(await session.sendUnsentTitles().spaces.isEmpty)
            #expect(await session.unsentTitle(pageId: "p1") == "Neu")
            #expect(StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/pages/verification-info"))
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/pages/update"))
            // "Edit" through another lock (the page was approved instead) doesn't count.
            #expect(await session.sendUnsentTitles(consented: ["p1": .approved]).spaces.isEmpty)
            #expect(await session.sendUnsentTitles(consented: ["p1": .verified]).spaces == ["s1"])
            #expect(await session.unsentTitle(pageId: "p1") == nil)

            await session.keepUnsentTitle("Zwei", pageId: "p1", spaceId: "s1")
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p1", "title": "Zwei", "status": "invalidated"}}"# }
            #expect(await session.sendUnsentTitles().spaces == ["s1"])
            #expect(await session.unsentTitle(pageId: "p1") == nil)
            await removeCaches()
        }

        /// Without the license feature nothing is asked, nor on Docmost 0.97, whose edits kept a verification and whose
        /// web didn't ask: every page edits as before.
        @Test(arguments: [(["bases"], "0.98.0"), (["page:verification"], "0.97.0")])
        func nothingAskedWithoutTheLock(features: [String], version: String) async throws {
            let (session, loader) = try await licensed(features, version: version)
            defer { resetStub() }
            StubURLProtocol.requests.withLock { $0 = [] }
            #expect(await loader.verification(of: try Self.page(canEdit: true))?.status == "none")
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/pages/verification-info"))
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// Signed in to a on Docmost `version` with `features` in the license; the loader of page p1.
        private func licensed(_ features: [String], version: String = "0.98.0") async throws -> (AppSession, PageLoader) {
            let quoted = features.map { "\"\($0)\"" }.joined(separator: ", ")
            // One answer for users/me, workspace/entitlements and version alike.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}, "currentVersion": "\#(version)", "tier": "enterprise", "features": [\#(quoted)]}}"#
            }
            let session = try await sessionOnA()
            StubURLProtocol.body.withLock { $0 = nil }
            let ready = try #require(session.ready)
            try #require(ready.entitlements.has(features[0]) && ready.serverVersion == version)
            return (session, PageLoader(pageId: "p1", owner: ready, session: session))
        }

        private func resetStub() {
            StubURLProtocol.status.withLock { $0 = 200 }
            StubURLProtocol.body.withLock { $0 = nil }
        }

        private static func page(canEdit: Bool) throws -> Page {
            try JSONDecoder().decode(Page.self, from: Data(#"{"id": "p1", "slugId": "Ab12", "title": "Freigabe", "spaceId": "s1", "permissions": {"canEdit": \#(canEdit)}}"#.utf8))
        }
    }
}
