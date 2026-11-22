import Foundation
import Synchronization
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

        /// A held connect asks the server before its changes go: a reconnect always, the first connect without an answer
        /// of the last 5 s.
        @Test func heldConnectsAskFirst() {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let first = EngineHold(open: 1, connect: 1), again = EngineHold(open: 1, connect: 2)
            #expect(!VerifiedPage.asksFirst(first, answeredAt: now.addingTimeInterval(-2), now: now))
            #expect(VerifiedPage.asksFirst(first, answeredAt: now.addingTimeInterval(-6), now: now))
            #expect(VerifiedPage.asksFirst(first, answeredAt: nil, now: now))
            #expect(VerifiedPage.asksFirst(again, answeredAt: now, now: now))
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

        /// "Edit" chosen while the app sends kept titles on its own (back in the app, a slow server) sends the page's title
        /// once that send is done. The page's send used to be dropped meanwhile, and the app's own skips a verified page:
        /// the title stayed on the device for as long as the page was open, which said it goes once the server answers.
        @Test(.timeLimit(.minutes(1))) func keptTitleGoesAfterEditWhileTheAppSendsItsOwn() async throws {
            let (session, _) = try await licensed(["page:verification"])
            let (released, release) = AsyncStream<Void>.makeStream()
            defer {
                release.finish()
                StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
                StubURLProtocol.beforeNextAnswer.withLock { $0 = nil }
                resetStub()
                UnsentChanges.removeAll(server: a)
            }
            await session.keepUnsentTitle("Neu", pageId: "p1", spaceId: "s1")
            // One answer for the verification and the rename alike.
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p1", "title": "Neu", "status": "verified"}}"# }
            // The app's send waits for the page's verification.
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/pages/verification-info" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { for await _ in released {} } }
            let appsOwn = Task { await session.sendUnsentTitles() }
            while StubURLProtocol.beforeNextAnswer.withLock({ $0 != nil }) { try await Task.sleep(for: .milliseconds(10)) }

            let edit = PageTitleEdit()
            var reports: [String] = []
            let page = try Self.page(canEdit: true)
            let afterEdit = Task {
                await edit.showUnsent(of: page, consented: .verified, typing: { false }, isOffline: { false },
                                      session: session, changes: ContentChanges()) { reports.append($0) }
            }
            // Shown as not sent: the page's send has then come to the app's, which still waits.
            while edit.unsent == nil { try await Task.sleep(for: .milliseconds(10)) }
            release.finish()
            #expect(await appsOwn.value.spaces.isEmpty, "the app's own send skips the verified page")
            #expect(await afterEdit.value, "the page's send went after it")
            #expect(edit.unsent == nil && reports.isEmpty)
            #expect(await session.unsentTitle(pageId: "p1") == nil)
            await removeCaches()
        }

        /// The evening before, on Docmost 0.97, a verified page's title waited for the server (`UnsentEdits`); overnight it
        /// came back as 0.98, and iOS kept the app in memory. Back in the app, the title goes only once the license and
        /// version that returning asks for have come, and so waits for "Edit": whether it is sent before the question
        /// (the main view's task runs first) or while the question's answers wait (`whileAnswersWait`).
        @Test(arguments: [false, true])
        func keptTitleWaitsForTheLicenseAndVersionAskedFor(whileAnswersWait: Bool) async throws {
            let (session, _) = try await licensed(["page:verification"], version: "0.97.0")
            defer {
                resetStub()
                StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
                UnsentChanges.removeAll(server: a)
            }
            try #require(session.ready.map(PageLoader.checksVerification) == false)
            await session.keepUnsentTitle("Neu", pageId: "p1", spaceId: "s1")
            session.licenseAndVersionInterval = .zero
            // One answer for the user, license, version, verification and rename alike.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}, "currentVersion": "0.98.0", "tier": "enterprise", "features": ["page:verification"], "id": "p1", "title": "Neu", "status": "verified"}}"#
            }
            StubURLProtocol.requests.withLock { $0 = [] }
            let sent: Bool
            if whileAnswersWait {
                let titles = Mutex<Task<Bool, Never>?>(nil)
                StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/version" }
                StubURLProtocol.beforeNextAnswer.withLock {
                    $0 = {
                        titles.withLock { $0 = Task { @MainActor in !(await session.sendUnsentTitles().spaces.isEmpty) } }
                        // The titles' task reads the session before the version answers.
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                await session.refreshCurrentUser()
                sent = try await #require(titles.withLock { $0 }).value
            } else {
                sent = !(await session.sendUnsentTitles().spaces.isEmpty)
            }
            #expect(!sent)
            #expect(session.ready.map(PageLoader.checksVerification) == true)
            #expect(await session.unsentTitle(pageId: "p1") == "Neu")
            #expect(StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/pages/verification-info"))
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/pages/update"))
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
