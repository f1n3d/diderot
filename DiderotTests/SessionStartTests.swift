import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The start: saved content at once without an answer, the license and version kept, a sign-in it couldn't check tried again.
    @Suite struct Start: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// An earlier sign-in to a found a Business license; now the license check fails (the stub answers with a user).
        @Test func failedEntitlementsAnswerKeepsTheLicense() async throws {
            _ = try await sessionOnA()
            let cache = DiskCache(scope: a.absoluteString)
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await cache.write(business, key: CacheKey.entitlements)
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            await session.restore()
            #expect(session.ready?.entitlements == business)
            #expect(await cache.read(Entitlements.self, key: CacheKey.entitlements) == business, "the offline start reads it")
            await removeCaches()
        }

        /// Clear Saved Content after a sign-in to a that found a Business license, then a start without network.
        @Test func clearingTheCacheKeepsTheLicense() async throws {
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
            try await sessionOnA().clearCache()
            #expect(try await offlineSessionOnA().ready?.entitlements == business)
            await removeCaches()
        }

        /// Docmost names its version only if GitHub answers its release check: a sign-in without it and a start without
        /// network keep the version named before (so 0.97 content can still be added), also after Clear Saved Content.
        @Test func unknownVersionKeepsTheLastKnownOne() async throws {
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}, "currentVersion": "0.97.0"}}"#
            }
            let named = try await sessionOnA()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(named.ready?.hasDocmost097Features == true)
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            await session.restore()
            #expect(session.ready?.serverVersion == "0.97.0")
            await session.clearCache()
            #expect(try await offlineSessionOnA().ready?.serverVersion == "0.97.0")
            await removeCaches()
        }

        /// A start with saved content waits only `startDeadline` for a server that doesn't answer (behind a VPN that is
        /// off, its requests would wait 30 s): it shows the saved content, keeps trying and loads the session once answered.
        @Test func unansweredStartShowsTheSavedContent() async throws {
            _ = try await sessionOnA()
            StubURLProtocol.unanswered.withLock { $0 = 3 }  // the first try's user, license and version
            defer { StubURLProtocol.unanswered.withLock { $0 = 0 } }
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            session.startDeadline = .milliseconds(300)
            let start = ContinuousClock.now
            await session.restore()
            #expect(ContinuousClock.now - start < .seconds(5), "not the requests' timeout")
            #expect(session.ready?.restoredOffline == true, "the saved content")
            for _ in 0..<100 where session.ready?.restoredOffline == true { try await Task.sleep(for: .milliseconds(50)) }
            #expect(session.ready?.restoredOffline == false, "the next try was answered")
            await removeCaches()
        }

        /// A start with saved content ends as soon as the server answered, not at `startDeadline`: a switch to another
        /// saved server used to take that long, and a link to a page there opened it only then.
        @Test func answeredStartEndsBeforeTheDeadline() async throws {
            _ = try await sessionOnA()
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            session.startDeadline = .seconds(10)
            let start = ContinuousClock.now
            await session.restore()
            #expect(ContinuousClock.now - start < .seconds(5), "not the start deadline")
            #expect(session.ready?.restoredOffline == false, "the server's answer")
            await removeCaches()
        }

        /// Without saved content there is nothing to show instead: the start waits for a slow server as before.
        @Test func slowStartWithoutSavedContentWaits() async throws {
            await removeCaches()
            try store.save(StoredSession(serverURL: a, token: "a"))
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/users/me" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { try? await Task.sleep(for: .milliseconds(600)) } }
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            session.startDeadline = .milliseconds(200)
            await session.restore()
            #expect(session.ready?.server.url == a)
            #expect(session.ready?.restoredOffline == false)
            await removeCaches()
        }

        /// Without a network (flight mode) a start shows the saved content at once and doesn't ask the server: its
        /// requests could wait for their timeout.
        @Test func startWithoutANetworkShowsTheSavedContentAtOnce() async throws {
            _ = try await sessionOnA()
            StubURLProtocol.requests.withLock { $0 = [] }
            var environment = SessionEnvironment(protocolClasses: [StubURLProtocol.self])
            environment.hasNoNetwork = { true }
            let session = AppSession(sessionStore: store, environment: environment)
            await session.restore()
            #expect(session.ready?.restoredOffline == true)
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/users/me"))
            await removeCaches()
        }

        /// A start that can't reach the server and has nothing of it saved to show keeps the sign-in and says so (code review
        /// R40); trying again signs in once the server answers. It showed the sign-in screen without a word and tried no more.
        @Test func uncheckedStartKeepsTheSignInAndTriesAgain() async throws {
            let session = try await uncheckedStartOnA()
            #expect(try store.loadAccounts().sessions.map(\.token) == ["a"], "The saved sign-in went")
            StubURLProtocol.offline.withLock { $0 = true }
            await session.retryUncheckedSignIn()
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(session.ready == nil && session.uncheckedSignIn?.token == "a", "Still out of reach")
            await session.retryUncheckedSignIn()
            #expect(session.ready?.token == "a" && session.uncheckedSignIn == nil)
            await removeCaches()
        }

        /// The network changing (a VPN coming on) tries the unchecked sign-in again by itself.
        @Test func networkChangeTriesTheUncheckedSignInAgain() async throws {
            let (changes, change) = AsyncStream<Void>.makeStream()
            let session = try await uncheckedStartOnA {
                $0.networkReturns = {
                    for await _ in changes { return true }
                    return false
                }
            }
            #expect(session.ready == nil)
            change.yield()
            for _ in 0..<100 where session.ready == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(session.ready?.token == "a" && session.uncheckedSignIn == nil)
            await removeCaches()
        }

        /// Signing in anew there ends the saved sign-in's session on the server, as signing out does: it stayed open (code
        /// review R40).
        @Test func signingInAnewEndsTheUncheckedSignIn() async throws {
            let session = try await uncheckedStartOnA()
            let payload = Data(#"{"type":"access","exp":4102444800}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            let token = "e30.\(payload).sig"
            try await session.signIn(withToken: token, at: ServerInfo(url: a, workspace: nil))
            #expect(session.ready?.token == token)
            #expect(try store.pendingLogouts().map(\.token) == ["a"])
            try store.setPendingLogouts([])
            await removeCaches()
        }

        /// A retry that answers after the user moved on (here: to adding a server) changes nothing (code review R40).
        @Test func lateRetryKeepsWhatTheUserDid() async throws {
            let session = try await uncheckedStartOnA()
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in session.beginAddingServer() } }
            await session.retryUncheckedSignIn()
            let addsServer = if case .noServer = session.state { true } else { false }
            #expect(addsServer && session.ready == nil, "The late retry signed in")
            await removeCaches()
        }

        /// Another server's sign-in screen ends the unchecked sign-in: a retry there would have signed in with a's token as
        /// that server (code review R40).
        @Test func retryStaysWithItsServer() async throws {
            let session = try await uncheckedStartOnA()
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "w2", "name": "Other"}}"# }
            try await session.connect(to: b.absoluteString)
            StubURLProtocol.body.withLock { $0 = nil }
            await session.retryUncheckedSignIn()
            let signedOutAtB = if case .signedOut(let server) = session.state { server.url == b } else { false }
            #expect(signedOutAtB && session.uncheckedSignIn == nil)
            #expect(try store.loadAccounts().sessions.map(\.serverURL) == [a], "a's sign-in was saved for b")
            await removeCaches()
        }
    }
}
