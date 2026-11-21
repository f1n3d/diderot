import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Verified and approved pages (license feature `page:verification`, Docmost 0.98): any edit takes the verification
    /// back, so such a page opens read-only and asks first, as the web does; the engine waits for the status, whose first
    /// sync would send unsent changes.
    @Suite struct VerifiedPages: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// A lock makes the page read-only, after the reasons that already held; an unknown status waits, no lock edits.
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
            #expect(reason(.locked(.verified), of: readable) == .noPermission)
            #expect(reason(.locked(.verified), offline: true) == .offline)
            #expect(reason(.unknown, newer: "0.99.0") == .newerServer("0.99.0"))
        }

        /// With the license feature the status comes from the server and is kept for the saved copy; a server without
        /// enterprise code (404) has none; one that fails otherwise gives the kept status.
        @Test func statusComesFromTheServerAndIsKept() async throws {
            let (session, loader) = try await licensed(["page:verification"])
            defer { resetStub() }
            let page = try Self.page(canEdit: true)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"status": "in_approval", "type": "qms"}}"# }
            #expect(await loader.verification(of: page).lock == .inApproval)
            #expect(await loader.savedVerification(of: page.id)?.lock == .inApproval)

            StubURLProtocol.status.withLock { $0 = 500 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 500, "message": "Internal server error"}"# }
            #expect(await loader.verification(of: page).lock == .inApproval)

            StubURLProtocol.status.withLock { $0 = 404 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 404, "message": "Cannot POST /api/pages/verification-info"}"# }
            #expect(await loader.verification(of: page).status == "none")
            #expect(await loader.savedVerification(of: page.id)?.status == "none")
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// Without the license feature nothing is asked, nor on Docmost 0.97, whose edits kept a verification and whose
        /// web didn't ask: every page edits as before.
        @Test(arguments: [(["bases"], "0.98.0"), (["page:verification"], "0.97.0")])
        func nothingAskedWithoutTheLock(features: [String], version: String) async throws {
            let (session, loader) = try await licensed(features, version: version)
            defer { resetStub() }
            StubURLProtocol.requests.withLock { $0 = [] }
            #expect(await loader.verification(of: try Self.page(canEdit: true)).lock == nil)
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
