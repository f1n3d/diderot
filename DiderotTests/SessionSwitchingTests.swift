import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Switching servers, signing in and out: a late answer of one session changes nothing of the next.
    @Suite struct Switching: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// Sign Out tapped twice on a slow connection: the second tap finishes first and switches to b.
        @Test func doubleSignOutKeepsTheOtherServer() async throws {
            let session = try await sessionOnA()
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { await session.signOut() } }
            await session.signOut()
            // On a slow machine (CI) removing the web data takes longer than the first request's timeout, so the first
            // sign-out returns while the second is still switching to b.
            for _ in 0..<600 where session.ready == nil { try await Task.sleep(for: .milliseconds(100)) }
            #expect(session.ready?.server.url == b)
            #expect(try store.loadAccounts().sessions.map(\.serverURL) == [b])
            await removeCaches()
        }

        /// The user switches to b while the app revalidates a's user.
        @Test func lateUserAnswerKeepsTheSwitch() async throws {
            let session = try await sessionOnA()
            let other = StoredSession(serverURL: b, token: "b")
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { await session.switchTo(other) } }
            await session.refreshCurrentUser()
            #expect(session.ready?.server.url == b)
            #expect(try store.load()?.serverURL == b)
            await removeCaches()
        }

        /// The user switches to b and back while the app revalidates a's user: a changed user lands in the session from
        /// switching back, not in the copy from before.
        @Test func lateUserAnswerAfterSwitchingBackKeepsTheNewSession() async throws {
            let session = try await sessionOnA()
            let before = try #require(session.ready?.client)
            let other = StoredSession(serverURL: b, token: "b"), original = StoredSession(serverURL: a, token: "a")
            StubURLProtocol.beforeNextAnswer.withLock {
                $0 = {
                    await session.switchTo(other)
                    await session.switchTo(original)
                    StubURLProtocol.body.withLock {
                        $0 = #"{"data": {"user": {"id": "u1", "email": "u1@example.com", "name": "Renamed"}, "workspace": {"id": "w1", "name": "Docs"}}}"#
                    }
                }
            }
            await session.refreshCurrentUser()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(session.ready?.currentUser.user.name == "Renamed")
            #expect(session.ready?.client !== before)
            await removeCaches()
        }

        /// Sign Out takes effect on the device before the server is asked (behind a VPN that is off it takes its 30 s): an
        /// app left meanwhile stayed signed in, with its content there on the next start.
        @Test func signOutTakesEffectBeforeTheServerAnswers() async throws {
            let session = try await sessionOnA()
            let a = a
            let signedOutFirst = Mutex<Bool?>(nil)
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                signedOutFirst.withLock { $0 = !session.accounts.contains { $0.serverURL == a } }
            } }
            await session.signOut()
            #expect(signedOutFirst.withLock { $0 } == true)
            await removeCaches()
        }

        /// A link to the other saved server switches there only when it opens a page.
        @Test func linkToAnotherServerSwitchesOnlyForAPage() async throws {
            let session = try await sessionOnA()
            #expect(!AppNavigation().handle(URL(string: "https://b.example.com/settings/members")!, session: session))
            #expect(session.ready?.server.url == a)
            await removeCaches()
        }

        /// Returning to the app rewrites the session only for a changed user, as every view reading it would redraw; the
        /// cached user an offline start needs is written every time, in case iOS purged the cache meanwhile.
        @Test func refreshWritesTheStateOnlyForAChangedUser() async throws {
            let session = try await sessionOnA()
            let cache = try #require(session.ready?.cache)
            await cache.remove(key: CacheKey.currentUser)
            let writes = Mutex(0)
            withObservationTracking { _ = session.state } onChange: { writes.withLock { $0 += 1 } }
            await session.refreshCurrentUser()
            #expect(writes.withLock { $0 } == 0)
            #expect(await cache.read(CurrentUser.self, key: CacheKey.currentUser) != nil, "an offline start finds the user")
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"user": {"id": "u1", "email": "u1@example.com", "name": "Renamed"}, "workspace": {"id": "w1", "name": "Docs"}}}"#
            }
            await session.refreshCurrentUser()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(writes.withLock { $0 } == 1 && session.ready?.currentUser.user.name == "Renamed")
            await removeCaches()
        }

        /// A browser sign-in without a valid token leaves the sign-in screen alone; a failed MFA step returns to it.
        @Test func failedSignInStepsKeepTheSignInScreen() async throws {
            let session = try await sessionOnA()
            session.handleUnauthorized()
            let server = try #require(session.server)
            let writes = Mutex(0)
            withObservationTracking { _ = session.state } onChange: { writes.withLock { $0 += 1 } }
            await #expect(throws: APIError.self) { try await session.signIn(withToken: "not-a-token", at: server) }
            #expect(writes.withLock { $0 } == 0, "no switch to “authenticating” and back")
            // Without the transfer token from the first step, the MFA step fails before any request.
            let challenge = try JSONDecoder().decode(MFAChallenge.self, from: Data(#"{"userHasMfa": true}"#.utf8))
            await #expect(throws: APIError.self) { try await session.completeMFA(challenge, code: "123456", at: server) }
            let signedOut = if case .signedOut(let server) = session.state { server.url == a } else { false }
            #expect(signedOut)
            await removeCaches()
        }

        /// The sign-in screen of a sends its password or MFA code after a link switched the app to b: nothing goes to b, and
        /// b stays signed in. Both used to go to b, whose answer showed b's sign-in screen.
        @Test func signInForAServerNoLongerShownChangesNothing() async throws {
            let session = try await sessionOnA()
            session.handleUnauthorized()
            let server = try #require(session.server)
            await session.switchTo(StoredSession(serverURL: b, token: "b"))
            StubURLProtocol.requests.withLock { $0 = [] }
            await #expect(throws: CancellationError.self) {
                try await session.signIn(email: "u1@example.com", password: "secret", at: server)
            }
            let challenge = try JSONDecoder().decode(MFAChallenge.self, from: Data(#"{"userHasMfa": true}"#.utf8))
            await #expect(throws: CancellationError.self) { try await session.completeMFA(challenge, code: "123456", at: server) }
            #expect(session.ready?.server.url == b)
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains { $0.contains("/api/auth/") || $0.contains("/api/mfa/") })
            await removeCaches()
        }

        /// The app switches to b while a's sign-in waits for the server: its failure leaves b alone, where it used to show
        /// a's sign-in screen again. Links wait meanwhile, as such a switch would come from one.
        @Test func lateSignInAnswerKeepsTheSwitch() async throws {
            let session = try await sessionOnA()
            session.handleUnauthorized()
            let server = try #require(session.server)
            #expect(session.opensLinks, "on the sign-in screen")
            let other = StoredSession(serverURL: b, token: "b")
            let opensLinks = Mutex<Bool?>(nil)
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/auth/login" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                opensLinks.withLock { $0 = session.opensLinks }
                await session.switchTo(other)
            } }
            // The stub's answer has no token: the sign-in fails.
            await #expect(throws: APIError.self) { try await session.signIn(email: "u1@example.com", password: "secret", at: server) }
            #expect(opensLinks.withLock { $0 } == false, "while signing in")
            #expect(session.ready?.server.url == b)
            await removeCaches()
        }

        /// a's server rejects the stored sign-in at the start, after the saved selection moved to b: a's sign-in goes, b's
        /// stays. The current one went, by then b's.
        @Test func rejectedStartRemovesItsOwnSignIn() async throws {
            try store.save(StoredSession(serverURL: b, token: "b"))
            try store.save(StoredSession(serverURL: a, token: "a"))
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            let store = store, b = b
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/users/me" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { _ = try? store.select(serverURL: b) } }
            StubURLProtocol.status.withLock { $0 = 401 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 401, "message": "Unauthorized"}"# }
            await session.restore()
            StubURLProtocol.status.withLock { $0 = 200 }
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(try store.loadAccounts().sessions.map(\.serverURL) == [b])
            await removeCaches()
        }

        /// After an offline start, the user switches to b before the connection is back. The reconnect's user request
        /// waits for the switch: on a GitHub runner another request took the hook and the test didn't wait at all (0.25 s).
        @Test func lateReconnectKeepsTheSwitch() async throws {
            let session = try await offlineSessionOnA()
            let other = StoredSession(serverURL: b, token: "b")
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/users/me" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { await session.switchTo(other) } }
            await session.reconnectIfNeeded()
            #expect(session.ready?.server.url == b)
            #expect(try store.load()?.serverURL == b)
            await removeCaches()
        }

        /// The connection returns as the user signs out of a: the reconnect ends while sign-out still removes local data.
        @Test func reconnectDuringSignOutKeepsTheSignOut() async throws {
            let session = try await offlineSessionOnA()
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { Task { await session.reconnectIfNeeded() } } }
            await session.signOut()
            #expect(session.ready?.server.url == b)
            #expect(try store.loadAccounts().sessions.map(\.serverURL) == [b])
            await removeCaches()
        }

        /// On an iPad, a second window opens while the first shows the sign-in screen after the session ended.
        @Test func secondWindowKeepsTheSignInScreen() async throws {
            try store.save(StoredSession(serverURL: a, token: "a"))
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            await session.restoreAtLaunch()
            try #require(session.ready?.server.url == a)
            session.handleUnauthorized()
            await session.restoreAtLaunch()
            #expect(session.server?.url == a, "still a's sign-in screen, not server setup")
            await removeCaches()
        }

        /// A server added before keeps the URL it was added with when its address is typed again in another spelling: what
        /// the app keeps for it, such as its kept titles, is named by that URL.
        @Test func aServerTypedAgainKeepsTheURLItWasAddedWith() async throws {
            let added = URL(string: "https://A.example.com:443")!
            try store.save(StoredSession(serverURL: added, token: "a"))
            defer { UnsentChanges.removeAll(server: added) }
            try await UnsentChanges.store(server: added, userId: "u1").update([String: UnsentTitle].self, key: CacheKey.unsentTitles, initial: [:]) {
                $0["p1"] = UnsentTitle(title: "Wartet", spaceId: nil)
            }
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            await session.restore()
            try #require(session.ready?.server.url == added)

            session.beginAddingServer()
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "w1", "name": "Docs"}}"# }
            let server = try await session.connect(to: "a.example.com")
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(server.url == added)
            let payload = Data(#"{"type":"access","exp":4102444800}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            try await session.signIn(withToken: "e30.\(payload).sig", at: server)
            #expect(session.ready?.server.url == added)
            #expect(try store.loadAccounts().sessions.map(\.serverURL) == [added])
            #expect(await session.unsentTitle(pageId: "p1") == "Wartet")
            try store.setPendingLogouts([])
            await DiskCache(scope: added.absoluteString).removeAll()
            await removeCaches()
        }
    }
}
