import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The start: saved content at once without an answer, the license and version kept (and asked again on returning to
    /// the app), a sign-in it couldn't check tried again.
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

        /// iOS kept the app in memory overnight, while the server went from Docmost 0.97 to 0.98 and its license gained
        /// page verification: returning to the app finds both, so a verified page asks before an edit takes its
        /// verification back. An offline start finds them too; an answer that doesn't come keeps them, and the same
        /// answers again rewrite no session (every view reading it would redraw).
        @Test func returningToTheAppFindsAnUpgradeAndALicenseChange() async throws {
            StubURLProtocol.body.withLock { $0 = Self.answer(version: "0.97.0", features: ["bases"]) }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            let session = try await sessionOnA()
            try #require(session.ready.map(PageLoader.checksVerification) == false)
            session.licenseAndVersionInterval = .zero
            StubURLProtocol.body.withLock { $0 = Self.answer(version: "0.98.0", features: ["bases", "page:verification"]) }
            await session.refreshCurrentUser()
            #expect(session.ready?.serverVersion == "0.98.0")
            #expect(session.ready?.entitlements.has("page:verification") == true)
            #expect(session.ready.map(PageLoader.checksVerification) == true)
            let cache = DiskCache(scope: a.absoluteString)
            #expect(await cache.read(String.self, key: CacheKey.serverVersion) == "0.98.0")
            #expect(await cache.read(Entitlements.self, key: CacheKey.entitlements)?.has("page:verification") == true)

            let writes = Mutex(0)
            withObservationTracking { _ = session.state } onChange: { writes.withLock { $0 += 1 } }
            await session.refreshCurrentUser()
            #expect(writes.withLock { $0 } == 0, "the same answers")
            // A user alone: no version named, and no license in it.
            StubURLProtocol.body.withLock { $0 = nil }
            await session.refreshCurrentUser()
            #expect(writes.withLock { $0 } == 0, "no answers")
            #expect(session.ready?.serverVersion == "0.98.0" && session.ready?.entitlements.has("page:verification") == true)
            await removeCaches()
        }

        /// Docmost 0.96 and 0.97 ask GitHub at every version request, which allows 60 an hour from one address: returning
        /// to the app asks for the license and version only once `licenseAndVersionInterval` has passed since they were
        /// last asked for, and windows of an iPad coming back together ask once.
        @Test func licenseAndVersionAreAskedOncePerInterval() async throws {
            let session = try await sessionOnA()
            StubURLProtocol.requests.withLock { $0 = [] }
            await session.refreshCurrentUser()
            #expect(StubURLProtocol.requests.withLock { $0 } == ["a.example.com/api/users/me"], "just signed in")

            session.licenseAndVersionInterval = .seconds(1)
            try await Task.sleep(for: .milliseconds(1200))
            // Another window comes back while this one's requests wait for their answers.
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/users/me" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { await session.refreshCurrentUser() } }
            StubURLProtocol.requests.withLock { $0 = [] }
            await session.refreshCurrentUser()
            let requests = StubURLProtocol.requests.withLock { $0 }
            #expect(requests.filter { $0 == "a.example.com/api/version" }.count == 1)
            #expect(requests.filter { $0 == "a.example.com/api/workspace/entitlements" }.count == 1)
            #expect(requests.filter { $0 == "a.example.com/api/users/me" }.count == 2)
            await removeCaches()
        }

        /// Flight mode just off, the app comes back before Wi-Fi has joined: neither the license nor the version came, and
        /// the requests never reached the server (nor GitHub), so the next return asks again rather than 15 minutes on.
        @Test func unansweredLicenseAndVersionAreAskedAgain() async throws {
            let session = try await sessionOnA()
            session.licenseAndVersionInterval = .seconds(1)
            try await Task.sleep(for: .milliseconds(1200))
            StubURLProtocol.offline.withLock { $0 = true }
            await session.refreshCurrentUser()
            StubURLProtocol.offline.withLock { $0 = false }
            StubURLProtocol.requests.withLock { $0 = [] }
            await session.refreshCurrentUser()
            let requests = StubURLProtocol.requests.withLock { $0 }
            #expect(requests.contains("a.example.com/api/version"))
            #expect(requests.contains("a.example.com/api/workspace/entitlements"))
            await removeCaches()
        }

        /// One answer for users/me, workspace/entitlements and version alike: Docmost `version` with these license features.
        private static func answer(version: String, features: [String]) -> String {
            let quoted = features.map { "\"\($0)\"" }.joined(separator: ", ")
            return #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}, "currentVersion": "\#(version)", "tier": "enterprise", "features": [\#(quoted)]}}"#
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

        /// A sign-in there that fails, or that needs MFA set up first, leaves the screen waiting for the saved sign-in
        /// again: Try Again and the retries on a network change went with it, and nothing checked the saved sign-in until a
        /// relaunch.
        @Test func failedSignInKeepsTheUncheckedSignIn() async throws {
            let networkChanged = Mutex(false)
            let session = try await uncheckedStartOnA {
                $0.networkReturns = {
                    while !Task.isCancelled {
                        if networkChanged.withLock({ $0 }) { return true }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    return false
                }
            }
            let server = ServerInfo(url: a, workspace: nil)
            StubURLProtocol.offline.withLock { $0 = true }
            await #expect(throws: APIError.self) { try await session.signIn(email: "u1@example.com", password: "secret", at: server) }
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(session.uncheckedSignIn?.token == "a", "after a failed sign-in")
            StubURLProtocol.body.withLock { $0 = #"{"data": {"requiresMfaSetup": true}}"# }
            let outcome = try await session.signIn(email: "u1@example.com", password: "secret", at: server)
            StubURLProtocol.body.withLock { $0 = nil }
            let needsSetup = if case .mfaRequired(let challenge) = outcome { challenge.needsSetup } else { false }
            #expect(needsSetup && session.uncheckedSignIn?.token == "a", "after a sign-in that needs MFA set up first")
            networkChanged.withLock { $0 = true }
            for _ in 0..<100 where session.ready == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(session.ready?.token == "a" && session.uncheckedSignIn == nil, "the network change tried it again")
            await removeCaches()
        }

        /// While the sign-in screen asks for an MFA code, the saved sign-in waits, a wrong code too: the app coming back from
        /// the authenticator app tried it, and its answer took over the code step, the sheet going with the sign-in screen
        /// into the saved sign-in's account. Once the code sheet closes without a sign-in, the screen waits for it again.
        @Test func codeStepKeepsTheUncheckedSignInWaiting() async throws {
            let networkChanged = Mutex(false)
            let session = try await uncheckedStartOnA {
                $0.networkReturns = {
                    while !Task.isCancelled {
                        if networkChanged.withLock({ $0 }) { return true }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    return false
                }
            }
            let server = ServerInfo(url: a, workspace: nil)
            var challenge = try await mfaChallenge(signingIn: session, at: server)
            await session.retryUncheckedSignIn()
            networkChanged.withLock { $0 = true }
            try await Task.sleep(for: .milliseconds(200))
            #expect(session.ready == nil && session.uncheckedSignIn == nil, "a retry took over the code step")
            challenge.mfaToken = "t"
            await #expect(throws: APIError.self) { try await session.completeMFA(challenge, code: "123456", at: server) }
            await session.retryUncheckedSignIn()
            #expect(session.ready == nil && session.uncheckedSignIn == nil, "a retry took over the code step after a wrong code")
            session.endMFA(at: server)
            #expect(session.uncheckedSignIn?.token == "a", "after the code sheet closed")
            for _ in 0..<100 where session.ready == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(session.ready?.token == "a" && session.uncheckedSignIn == nil, "the network change tried it again")
            await removeCaches()
        }

        /// The code sheet closed while its code is verified (Cancel stays enabled): that sign-in's failure leaves the screen
        /// waiting for the saved sign-in again.
        @Test func codeSheetClosedWhileVerifyingWaitsAgain() async throws {
            let session = try await uncheckedStartOnA()
            let server = ServerInfo(url: a, workspace: nil)
            var challenge = try await mfaChallenge(signingIn: session, at: server)
            challenge.mfaToken = "t"
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/mfa/verify" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in session.endMFA(at: server) } }
            await #expect(throws: APIError.self) { try await session.completeMFA(challenge, code: "123456", at: server) }
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
            let signedOut = if case .signedOut(let current) = session.state { current.url == a } else { false }
            #expect(signedOut && session.uncheckedSignIn?.token == "a")
            await removeCaches()
        }

        /// The sign-in screen with an MFA code sheet for a, after a password sign-in there.
        private func mfaChallenge(signingIn session: AppSession, at server: ServerInfo) async throws -> MFAChallenge {
            StubURLProtocol.body.withLock { $0 = #"{"data": {"userHasMfa": true}}"# }
            let outcome = try await session.signIn(email: "u1@example.com", password: "secret", at: server)
            StubURLProtocol.body.withLock { $0 = nil }
            guard case .mfaRequired(let challenge) = outcome, !challenge.needsSetup else {
                Issue.record("No MFA code asked for")
                throw CancellationError()
            }
            return challenge
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

        /// Try Again answering after another user signed in there leaves that user's data alone. The late answer emptied
        /// the cache, removed the staged uploads and the web editor's storage with its unsynced edits, and left its own
        /// user cached, so the next start or switch back removed them again.
        @Test func lateRetryKeepsTheNextUsersData() async throws {
            let removed = Mutex<[String]>([])
            let session = try await uncheckedStartOnA {
                $0.removeLocalData = { url, _ in removed.withLock { $0.append(url.host() ?? "") } }
            }
            let a = a
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/users/me" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in await Self.signInAnotherUser(to: session, at: a) } }
            await session.retryUncheckedSignIn()
            #expect(session.ready?.currentUser.user.id == "u2")
            #expect(await cachedUserId(a) == "u2", "the late answer's user was cached")
            #expect(removed.withLock { $0 }.isEmpty, "the late answer removed the local data")
            try store.setPendingLogouts([])
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

        /// What an earlier run left goes once per process, at its start. Each new session's start removed every server's
        /// staged uploads, media loaders' files and running downloads again, this run's too: a test's session took the
        /// files of tests running alongside.
        @Test func aLaterStartLeavesThisRunsFiles() async throws {
            // The process's first start removes what an earlier run left; normally the test host app's own did.
            await AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self])).restoreAtLaunch()
            let server = URL(string: "https://temp-\(UUID().uuidString).example.com")!
            defer { TempFile.removeAll(server: server, uploads: true) }
            let upload = try UploadFile.camera(Data("x".utf8), server: server)
            let loaded = FileManager.default.temporaryDirectory.appending(path: "media-\(UUID().uuidString)")
            try Data("x".utf8).write(to: loaded)
            let media = try TempFile.move(loaded, into: TempFile.sessionMedia(server: server))
            // A client's download as it loads (`APIClient.downloadFile`).
            let download = APIClient.downloadsDirectory.appending(path: "\(UUID().uuidString)/\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: download.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: download)

            await AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self])).restoreAtLaunch()
            func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
            #expect(exists(upload.fileURL), "a running upload reads it")
            #expect(exists(media), "a media loader shows it")
            #expect(exists(download), "a client loads it")
        }
    }
}
