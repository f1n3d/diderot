import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Sign-outs the server didn't get, and what signing out or removing a server leaves on the device.
    @Suite struct SignOuts: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// Signed out offline: the server session would stay valid, so its token waits and the next try ends it.
        @Test func signOutOfflineEndsTheSessionLater() async throws {
            let session = try await sessionOnA()
            StubURLProtocol.offline.withLock { $0 = true }
            await session.signOut()
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(try store.pendingLogouts().map(\.serverURL) == [a])
            await session.sendPendingLogouts()
            #expect(try store.pendingLogouts().isEmpty)
            await removeCaches()
        }

        /// The browser's token, captured but not signed in with (the server out of reach, the app on another server meanwhile),
        /// waits as a sign-out: unused, its session stayed valid on the server (code review R12).
        @Test(arguments: [false, true]) func browserTokenNotSignedInWithIsSignedOut(switched: Bool) async throws {
            let session = try await sessionOnA()
            session.handleUnauthorized()
            let server = try #require(session.server)
            let payload = Data(#"{"type":"access","exp":4102444800}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            let token = "e30.\(payload).sig"
            if switched {
                await session.switchTo(StoredSession(serverURL: b, token: "b"))
            }
            StubURLProtocol.offline.withLock { $0 = true }
            defer { StubURLProtocol.offline.withLock { $0 = false } }
            await #expect(throws: (any Error).self) { try await session.signIn(withToken: token, at: server) }
            #expect(try store.pendingLogouts().filter { $0.token == token }.map(\.serverURL) == [a])
            try store.setPendingLogouts([])
            await removeCaches()
        }

        /// A waiting sign-out whose token expired long ago, or that the server no longer knows (401), is dropped.
        @Test(arguments: [false, true]) func waitingSignOutIsDroppedWhenItCanEnd(expired: Bool) async throws {
            let session = try await sessionOnA()
            // A token that expired in 1970 (only its claims count here).
            let payload = Data(#"{"type":"access","exp":1000}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            try store.setPendingLogouts([StoredSession(serverURL: a, token: expired ? "e30.\(payload).sig" : "stale")])
            if !expired {
                StubURLProtocol.status.withLock { $0 = 401 }
                StubURLProtocol.body.withLock { $0 = #"{"statusCode": 401, "message": "Unauthorized"}"# }
            } else {
                StubURLProtocol.offline.withLock { $0 = true }  // dropped without asking the server
            }
            defer {
                StubURLProtocol.status.withLock { $0 = 200 }
                StubURLProtocol.body.withLock { $0 = nil }
                StubURLProtocol.offline.withLock { $0 = false }
            }
            await session.sendPendingLogouts()
            #expect(try store.pendingLogouts().isEmpty)
            await removeCaches()
        }

        /// A waiting sign-out whose token expired an hour ago by the device's clock goes to the server, which judges it:
        /// a clock running ahead dropped sign-outs whose sessions the server still took (code review R30). So does a stored
        /// sign-in the start finds expired.
        @Test func justExpiredSignOutAsksTheServer() async throws {
            let session = try await sessionOnA()
            let payload = Data(#"{"type":"access","exp":\#(Int(Date.now.timeIntervalSince1970) - 3600)}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            let token = "e30.\(payload).sig"
            try store.setPendingLogouts([StoredSession(serverURL: a, token: token)])
            StubURLProtocol.offline.withLock { $0 = true }
            await session.sendPendingLogouts()
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(try store.pendingLogouts().map(\.token) == [token], "out of reach, it waits")
            StubURLProtocol.requests.withLock { $0 = [] }
            await session.sendPendingLogouts()
            #expect(StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/auth/logout"))
            #expect(try store.pendingLogouts().isEmpty)

            try store.save(StoredSession(serverURL: a, token: token))
            StubURLProtocol.offline.withLock { $0 = true }
            await session.restore()
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(session.ready == nil)
            #expect(try store.pendingLogouts().map(\.token) == [token])
            try store.setPendingLogouts([])
            await removeCaches()
        }

        /// Signed out, a server's offline copies stay for the same person, and its sign-in screen can remove them: the
        /// server was in no list anymore where they could be (code review R16). A signed-in server's stay.
        @Test func signedOutServerClearsItsSavedContent() async throws {
            let session = try await sessionOnA()
            let server = try #require(session.server)
            await DiskCache(scope: a.absoluteString).write(["page"], key: CacheKey.recentlyOpened)
            await session.clearSavedContent(of: server)
            #expect(await session.hasSavedContent(of: server), "signed in, its copies stay")
            session.handleUnauthorized()
            #expect(await session.hasSavedContent(of: server))
            await session.clearSavedContent(of: server)
            #expect(await !session.hasSavedContent(of: server))
            await removeCaches()
        }

        /// Clearing the cache, removing another server and signing out remove what the offline cache doesn't cover (files,
        /// web editor data) for that server; clearing the cache keeps the files staged for upload, which a running upload
        /// reads.
        @Test func localDataGoesWithTheServersData() async throws {
            try store.save(StoredSession(serverURL: b, token: "b"))
            try store.save(StoredSession(serverURL: a, token: "a"))
            var removed: [String] = []
            var environment = SessionEnvironment(protocolClasses: [StubURLProtocol.self])
            environment.removeLocalData = { url, uploads in removed.append("\(url.host() ?? "")\(uploads ? " with uploads" : "")") }
            let session = AppSession(sessionStore: store, environment: environment)
            await session.restore()
            try #require(session.ready?.server.url == a && removed.isEmpty)
            await session.clearCache()
            await session.removeAccount(StoredSession(serverURL: b, token: "b"))
            await session.signOut()
            #expect(removed == ["a.example.com", "b.example.com with uploads", "a.example.com with uploads"])
            await removeCaches()
        }

        /// The Keychain keeps sign-ins when the app is deleted: at a reinstall's first start they end, as on signing out,
        /// where the app used to start signed in. An update keeps its sign-ins, saved after its data were created, and a
        /// later start doesn't look again (code review R30).
        @Test(arguments: [true, false]) func signInsOfAnEarlierInstallEnd(reinstalled: Bool) throws {
            try store.save(StoredSession(serverURL: b, token: "b"))
            try store.save(StoredSession(serverURL: a, token: "a"))
            let suite = "install-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            session.endSignInsOfAnEarlierInstall(defaults: defaults, installed: .now + (reinstalled ? 3600 : -3600))
            #expect(try store.loadAccounts().sessions.map(\.token).sorted() == (reinstalled ? [] : ["a", "b"]))
            #expect(try store.pendingLogouts().map(\.token).sorted() == (reinstalled ? ["a", "b"] : []))
            try store.save(StoredSession(serverURL: a, token: "a2"))
            session.endSignInsOfAnEarlierInstall(defaults: defaults, installed: .now + 3600)
            #expect(try store.loadAccounts().sessions.contains { $0.token == "a2" }, "once per install")
            try store.setPendingLogouts([])
        }
    }
}
