import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

/// The offline cache is per server, so someone else signing in there must not see the previous user's pages.
struct AppSessionTests {
    @Test func signInOfAnotherUserOrWorkspaceClearsTheCache() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "app-session-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = DiskCache(scope: "server", baseDirectory: base)
        let alice = try user("alice"), bob = try user("bob"), bobElsewhere = try user("bob", workspace: "w2")
        /// Signs `user` in on a cache that holds a page.
        func pageSurvives(signInOf user: CurrentUser) async -> Bool {
            await cache.write(["page"], key: CacheKey.recentlyOpened)
            let removed = await AppSession.storeCurrentUser(user, in: cache)
            let survives = await cache.read([String].self, key: CacheKey.recentlyOpened) != nil
            #expect(removed == !survives, "sign-in also removes the web editor data when the result is true")
            return survives
        }

        // No cached user (iOS purged the cache): the web editor may hold this user's unsynced edits.
        #expect(await pageSurvives(signInOf: alice))
        #expect(await pageSurvives(signInOf: alice))
        #expect(await !pageSurvives(signInOf: bob))
        #expect(await !pageSurvives(signInOf: bobElsewhere))
    }

    /// The app sends its own name, not Docmost's: it isn't Docmost's app.
    @Test func userAgentNamesTheApp() {
        #expect(AppSession.userAgent.hasPrefix("Diderot/"))
        #expect(AppSession.userAgent.contains("CPU iPhone OS"))
    }

    private func user(_ id: String, workspace: String = "w1") throws -> CurrentUser {
        let json = #"{"user": {"id": "\#(id)", "email": "\#(id)@example.com"}, "workspace": {"id": "\#(workspace)", "name": "Docs"}}"#
        return try JSONDecoder().decode(CurrentUser.self, from: Data(json.utf8))
    }
}

/// The bundled editor follows Docmost 0.97 (`Engine/`): newer servers get read-only pages, unknown versions don't.
/// Only known 0.97 servers and newer get the blocks 0.96 doesn't know.
struct ServerVersionTests {
    @Test func versionsNewerThanTheEditor() {
        let versions = [("0.96.0", false), ("0.97.0", false), ("0.97.3", false), ("v0.97.0-beta.1", false),
                        ("0.98.0", true), ("v0.98.0-beta.1", true), ("1.0.0", true), ("", false), ("next", false)]
        for (version, newer) in versions {
            #expect(ReadySession.isNewerThanEditor(version) == newer, "\(version)")
        }
        #expect(!ReadySession.isNewerThanEditor(nil))
    }

    @Test func docmost097Features() throws {
        let versions: [(String?, Bool)] = [("0.96.4", false), ("0.97.0", true), ("v0.97.1", true), ("0.98.0", true),
                                           ("1.0.0", true), (nil, false), ("next", false)]
        for (version, expected) in versions {
            #expect(ReadySession.supportsDocmost097(version) == expected, "\(version ?? "nil")")
        }
    }
}

/// A late network answer must not undo a server switch or sign-out, open a closed editor or show under another view,
/// filter or query; a failed one must not drop the license, leave notifications marked read, make a database look
/// empty or drop a card from its offline copy; an edit or load must not take a card out of its detail sheet or bring a
/// deleted one back; a second window must not restore the session again. Serialized: the tests share `StubURLProtocol`.
@Suite(.serialized)
struct AppSessionRaceTests {
    // shortcut: sign-out also deletes the downloads, which can rarely break `TempFileTests` in a parallel Xcode run,
    // give both suites one serialized parent suite if it does.
    private let a = URL(string: "https://a.example.com")!, b = URL(string: "https://b.example.com")!
    private let store = SessionStore(keychain: MemorySecretStore())

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

    /// Unsent changes are kept per server and user: signing out keeps them for the next sign-in, removing a saved
    /// server deletes its own.
    /// A title kept for a page of a goes into a's store, also after a switch to b, where it used to be dropped. Forgetting a
    /// sent title removes only that one, not a newer one kept meanwhile.
    @Test func keptTitlesStayWithTheirSession() async throws {
        let session = try await sessionOnA()
        let aStore = try #require(session.ready?.unsentChanges)
        await session.switchTo(StoredSession(serverURL: b, token: "b"))
        await session.keepUnsentTitle("Neu", pageId: "p1", spaceId: nil, in: aStore)
        #expect(await aStore.read([String: UnsentTitle].self, key: CacheKey.unsentTitles)?["p1"]?.title == "Neu")
        #expect(await session.unsentTitle(pageId: "p1") == nil, "not in b's store")

        await session.keepUnsentTitle("Zwei", pageId: "p2", spaceId: nil)
        await session.forgetUnsentTitle(pageId: "p2", title: "Eins")
        #expect(await session.unsentTitle(pageId: "p2") == "Zwei")
        await session.forgetUnsentTitle(pageId: "p2", title: "Zwei")
        #expect(await session.unsentTitle(pageId: "p2") == nil)
        await removeCaches()
    }

    @Test func removingAServerDeletesItsUnsentChanges() async throws {
        let session = try await sessionOnA()
        let key = CacheKey.unsentChanges("p")
        await UnsentChanges.store(server: a, userId: "u1").writeData(Data("a".utf8), key: key)
        await UnsentChanges.store(server: b, userId: "u1").writeData(Data("b".utf8), key: key)
        #expect(await UnsentChanges.store(server: a, userId: "u2").readData(key: key) == nil)
        await session.removeAccount(StoredSession(serverURL: b, token: "b"))
        #expect(await UnsentChanges.store(server: b, userId: "u1").readData(key: key) == nil)
        await session.clearCache()
        await session.signOut()
        #expect(await UnsentChanges.store(server: a, userId: "u1").readData(key: key) == Data("a".utf8))
        UnsentChanges.removeAll(server: a)
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
        let writes = Mutex(0)
        withObservationTracking { _ = session.state } onChange: { writes.withLock { $0 += 1 } }
        await #expect(throws: APIError.self) { try await session.signIn(withToken: "not-a-token") }
        #expect(writes.withLock { $0 } == 0, "no switch to “authenticating” and back")
        // Without the transfer token from the first step, the MFA step fails before any request.
        let challenge = try JSONDecoder().decode(MFAChallenge.self, from: Data(#"{"userHasMfa": true}"#.utf8))
        await #expect(throws: APIError.self) { try await session.completeMFA(challenge, code: "123456") }
        let signedOut = if case .signedOut(let server) = session.state { server.url == a } else { false }
        #expect(signedOut)
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

    /// A request of a ends with 401 after the switch to b, e.g. because a's token was revoked meanwhile.
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

    @Test func lateUnauthorizedAnswerKeepsTheSwitch() async throws {
        let session = try await sessionOnA()
        let other = StoredSession(serverURL: b, token: "b")
        _ = try? await session.perform { () async throws -> Void in
            await session.switchTo(other)
            throw APIError.unauthorized(message: nil)
        }
        #expect(session.ready?.server.url == b)
        #expect(try store.loadAccounts().sessions.map(\.serverURL) == [b, a])
        await removeCaches()
    }

    /// An earlier sign-in to a found a Business license; now the license check fails (the stub answers with a user).
    @Test func failedEntitlementsAnswerKeepsTheLicense() async throws {
        _ = try await sessionOnA()
        let cache = DiskCache(scope: a.absoluteString)
        let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
        await cache.write(business, key: CacheKey.entitlements)
        let session = AppSession(sessionStore: store, protocolClasses: [StubURLProtocol.self])
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
        let session = AppSession(sessionStore: store, protocolClasses: [StubURLProtocol.self])
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
        let session = AppSession(sessionStore: store, protocolClasses: [StubURLProtocol.self])
        session.startDeadline = .milliseconds(300)
        let start = ContinuousClock.now
        await session.restore()
        #expect(ContinuousClock.now - start < .seconds(5), "not the requests' timeout")
        #expect(session.ready?.restoredOffline == true, "the saved content")
        for _ in 0..<100 where session.ready?.restoredOffline == true { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.ready?.restoredOffline == false, "the next try was answered")
        await removeCaches()
    }

    /// Without saved content there is nothing to show instead: the start waits for a slow server as before.
    @Test func slowStartWithoutSavedContentWaits() async throws {
        await removeCaches()
        try store.save(StoredSession(serverURL: a, token: "a"))
        StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/users/me" }
        defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { try? await Task.sleep(for: .milliseconds(600)) } }
        let session = AppSession(sessionStore: store, protocolClasses: [StubURLProtocol.self])
        session.startDeadline = .milliseconds(200)
        await session.restore()
        #expect(session.ready?.server.url == a)
        #expect(session.ready?.restoredOffline == false)
        await removeCaches()
    }

    /// On an iPad, a second window opens while the first shows the sign-in screen after the session ended.
    @Test func secondWindowKeepsTheSignInScreen() async throws {
        try store.save(StoredSession(serverURL: a, token: "a"))
        let session = AppSession(sessionStore: store, protocolClasses: [StubURLProtocol.self])
        await session.restoreAtLaunch()
        try #require(session.ready?.server.url == a)
        session.handleUnauthorized()
        await session.restoreAtLaunch()
        #expect(session.server?.url == a, "still a's sign-in screen, not server setup")
        await removeCaches()
    }

    /// Marking notifications read without a connection: list and badge must not look done until the next poll.
    @Test func failedMarkReadKeepsNotificationsUnread() async throws {
        let session = try await sessionOnA()
        let notifications = NotificationsStore(session: session)
        StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [{"id": "n1", "type": "page.updated"}], "meta": {"hasNextPage": false}}}"# }
        await notifications.loadList()
        StubURLProtocol.body.withLock { $0 = nil }
        let notification = try #require(notifications.listState.value?.first)
        StubURLProtocol.offline.withLock { $0 = true }
        await notifications.markRead(notification)
        #expect(notifications.listState.value?.first?.isUnread == true && notifications.unreadCount == 1)
        await notifications.markAllRead()
        #expect(notifications.listState.value?.first?.isUnread == true && notifications.unreadCount == 1)
        StubURLProtocol.offline.withLock { $0 = false }
        withExtendedLifetime(session) {}
        await removeCaches()
    }

    /// The user switches from Direct to All while Direct loads, and the All list arrives first.
    @Test func lateNotificationsAnswerKeepsTheNewFilter() async throws {
        let session = try await sessionOnA()
        let notifications = NotificationsStore(session: session)
        notifications.filter = .direct
        let direct = #"{"data": {"items": [], "meta": {"hasNextPage": false}}}"#
        StubURLProtocol.body.withLock { $0 = direct }
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            notifications.filter = .all
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [{"id": "n1", "type": "page.updated"}], "meta": {"hasNextPage": false}}}"# }
            await notifications.loadList()
            StubURLProtocol.body.withLock { $0 = direct }
        } }
        await notifications.loadList()
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(notifications.listState.value?.map(\.id) == ["n1"] && notifications.unreadCount == 1)
        withExtendedLifetime(session) {}
        await removeCaches()
    }

    /// Two favorites loads overlap (opening the tab, a rename's change) and the older answer arrives last: the newer
    /// list stays, with the new title.
    @Test func lateFavoritesAnswerKeepsTheNewerList() async throws {
        let session = try await sessionOnA()
        let favorites = FavoritesStore(session: session)
        func list(_ title: String) -> String {
            #"{"data": {"items": [{"id": "f1", "type": "page", "pageId": "p1", "page": {"id": "p1", "title": "\#(title)"}}], "meta": {"hasNextPage": false}}}"#
        }
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = list("Neu") }
            await favorites.loadList()
            StubURLProtocol.body.withLock { $0 = list("Alt") }
        } }
        await favorites.loadList()
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(favorites.listState.value?.first?.page?.title == "Neu")
        withExtendedLifetime(session) {}
        await removeCaches()
    }

    /// The user switches database views while the first view's rows load, and the second view's rows arrive first.
    @Test func lateRowsAnswerKeepsTheNewView() async throws {
        let session = try await sessionOnA()
        let pageId = "base-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "base.view.\(pageId)") }
        let model = BaseModel(pageId: pageId, session: session)
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "properties": [], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}, {"id": "v2", "name": "B", "type": "table", "position": "b"}]}}"#
        }
        await model.load()
        let second = try #require(model.views.last)
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
            await model.select(second)
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        } }
        await model.loadRows()
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.table.rows.map(\.id) == ["r2"] && !model.isLoadingRows)
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(pageId, viewId: "v2"))
        #expect(snapshot?.table?.rows.map(\.id) == ["r2"], "the second view's offline copy")
        await removeCaches()
    }

    /// Rows that fail to load show the error with "Try Again" instead of "No entries"; saved rows stay with a short
    /// notice (on opening, the page gives it), and a load cancelled by leaving the screen shows none.
    @Test func failedRowsLoadShowsTheError() async throws {
        let session = try await sessionOnA()
        let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
        // The rows request gets the base as its answer too, which isn't a page of rows.
        StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "b", "properties": [], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}]}}"# }
        await model.load()
        #expect(model.rowsError != nil && model.toast == nil)
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        await model.loadRows()
        StubURLProtocol.offline.withLock { $0 = true }
        await model.load()
        let reopened = BaseModel(pageId: model.pageId, session: session)
        await reopened.load()
        StubURLProtocol.offline.withLock { $0 = false }
        #expect(model.table.rows.map(\.id) == ["r1"] && model.rowsError == nil && model.toast != nil)
        #expect(reopened.table.rows.map(\.id) == ["r1"] && reopened.toast == nil, "the page reports it itself")
        model.toast = nil
        let leaving = Task { await model.load() }
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { leaving.cancel() } }
        await leaving.value
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.toast == nil)
        await removeCaches()
    }

    /// Reopened during a server error, the saved database shows with a notice (only offline, the page gives it); once
    /// deleted for good or no longer shared (404, 403), it shows the error and drops its saved copy and rows.
    @Test func goneDatabaseDropsItsSavedCopy() async throws {
        let session = try await sessionOnA()
        let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
        StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "b", "properties": [], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}]}}"# }
        await model.load()
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        await model.loadRows()
        StubURLProtocol.status.withLock { $0 = 500 }
        let failing = BaseModel(pageId: model.pageId, session: session)
        await failing.load()
        StubURLProtocol.status.withLock { $0 = 404 }
        StubURLProtocol.body.withLock { $0 = #"{"statusCode": 404, "message": "Page not found"}"# }
        let gone = BaseModel(pageId: model.pageId, session: session)
        await gone.load()
        StubURLProtocol.status.withLock { $0 = 200 }
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(failing.table.rows.map(\.id) == ["r1"] && failing.toast != nil)
        let shown: APIError? = if case .failed(let error) = gone.state { error as? APIError } else { nil }
        #expect(shown == .notFound(message: "Page not found"))
        let cache = try #require(session.ready?.cache)
        #expect(await cache.read(Base.self, key: CacheKey.base(model.pageId)) == nil)
        #expect(await cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1")) == nil)
        await removeCaches()
    }

    /// The user switches views while "Load More" waits, and the request fails: the view now shown gets no error toast.
    @Test func failedLoadMoreShowsNoToastInTheNewView() async throws {
        let session = try await sessionOnA()
        let pageId = "base-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "base.view.\(pageId)") }
        let model = BaseModel(pageId: pageId, session: session)
        // A table and a board by "s" (only the "No value" column); the rows request gets the base as its answer too.
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "properties": [{"id": "s", "name": "S", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}, {"id": "v2", "name": "B", "type": "kanban", "position": "b", "config": {"groupByPropertyId": "s"}}]}}"#
        }
        await model.load()
        let table = try #require(model.views.first), board = try #require(model.views.last)
        let more = #"{"data": {"items": [{"id": "r1", "cells": {}}], "meta": {"hasNextPage": true, "nextCursor": "c"}}}"#
        StubURLProtocol.body.withLock { $0 = more }
        await model.loadRows()
        /// While the next request waits, switches to `view`, whose rows have more; that request then gets the stub's
        /// user, not a page of rows.
        func switchWhileLoadingMore(to view: BaseView) {
            StubURLProtocol.body.withLock { $0 = more }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                await model.select(view)
                StubURLProtocol.body.withLock { $0 = nil }
            } }
        }
        switchWhileLoadingMore(to: board)
        await model.loadMoreTable()
        #expect(model.selectedView == board && model.toast == nil, "the table's request")
        switchWhileLoadingMore(to: table)
        await model.loadMore(columnId: BaseKanbanColumn.noValueId)
        #expect(model.selectedView == table && model.toast == nil, "the board's request")
        await removeCaches()
    }

    /// A card set to a status the board hides leaves the board, but its detail sheet keeps showing it and saving edits.
    @Test func cardInHiddenColumnStaysInItsSheet() async throws {
        let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
        await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
        let session = try await sessionOnA()
        let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
        // Board by "s" that hides "done"; the rows request gets the base as its answer too, so rows load again below.
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select", "typeOptions": {"choices": [{"id": "done", "name": "Done"}]}}], "views": [{"id": "v1", "name": "Board", "type": "kanban", "config": {"groupByPropertyId": "s", "hiddenChoiceIds": ["done"]}}]}}"#
        }
        await model.load()
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        await model.loadRows()
        StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"s": "done"}}}"# }
        await model.setCell(rowId: "r1", propertyId: "s", to: .string("done"))
        #expect(model.columns.map(\.list.rows.count) == [0], "the card left the board")
        #expect(model.row(id: "r1")?.cells["s"] == .string("done"), "the detail sheet still shows it")
        StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {}}}"# }
        await model.setCell(rowId: "r1", propertyId: "s", to: nil)
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r1"]], "a further edit saves and brings it back")
        await removeCaches()
    }

    /// The board reloads while the user sets a card to a hidden status, and the reload answers without the card.
    @Test func lateRowsAnswerKeepsTheCardInItsSheet() async throws {
        let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
        await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
        let session = try await sessionOnA()
        let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
        // Board by "s" that hides "done"; the rows request gets the base as its answer too, so rows load again below.
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select", "typeOptions": {"choices": [{"id": "done", "name": "Done"}]}}], "views": [{"id": "v1", "name": "Board", "type": "kanban", "config": {"groupByPropertyId": "s", "hiddenChoiceIds": ["done"]}}]}}"#
        }
        await model.load()
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        await model.loadRows()
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"s": "done"}}}"# }
            await model.setCell(rowId: "r1", propertyId: "s", to: .string("done"))
            StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
        } }
        await model.loadRows()
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]], "the reload's answer shows")
        #expect(model.row(id: "r1")?.cells["s"] == .string("done"), "the detail sheet still shows the card")
        await removeCaches()
    }

    /// The user edits a card and switches to a board without it before the answer arrives.
    @Test func lateWriteAnswerKeepsTheNewView() async throws {
        let (session, model) = try await boardsOnA()
        defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
        let second = try #require(model.views.last)
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
            await model.select(second)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"t": "x"}}}"# }
        } }
        await model.setCell(rowId: "r1", propertyId: "t", to: .string("x"))
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]])
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v2"))
        #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [["r2"]], "the second view's offline copy")
        await removeCaches()
    }

    /// The user edits a card and switches to a board that shows it too before the answer arrives.
    @Test func lateWriteAnswerUpdatesTheNewView() async throws {
        let (session, model) = try await boardsOnA()
        defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
        let second = try #require(model.views.last)
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            await model.select(second)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"t": "x"}}}"# }
        } }
        await model.setCell(rowId: "r1", propertyId: "t", to: .string("x"))
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.row(id: "r1")?.cells["t"] == .string("x"))
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v2"))
        #expect(snapshot?.columns?.first?.list.rows.first?.cells["t"] == .string("x"), "the second view's offline copy")
        await removeCaches()
    }

    /// The user creates an entry and switches to another board before the answer arrives.
    @Test func lateCreateAnswerKeepsTheNewView() async throws {
        let (session, model) = try await boardsOnA()
        defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
        let second = try #require(model.views.last)
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
            await model.select(second)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r3", "cells": {}}}"# }
        } }
        let created = await model.createRow()
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]])
        #expect(created == nil && model.lastCreatedRowId == nil, "no detail sheet opens there")
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v2"))
        #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [["r2"]], "the second view's offline copy")
        await removeCaches()
    }

    /// The user deletes a card and switches to a board without it before the delete fails.
    @Test func failedDeleteKeepsTheNewView() async throws {
        let (session, model) = try await boardsOnA()
        defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
        let second = try #require(model.views.last)
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
            await model.select(second)
            // An empty answer isn't JSON, so the delete fails.
            StubURLProtocol.body.withLock { $0 = "" }
        } }
        await model.deleteRow("r1")
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]] && model.toast != nil)
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v2"))
        #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [["r2"]], "the second view's offline copy")
        await removeCaches()
    }

    /// A reload the server answered before a delete arrives after it: the deleted card stays gone; it used to come back
    /// until the next reload.
    @Test func reloadAnsweredBeforeTheDeleteKeepsTheCardGone() async throws {
        let (session, model) = try await boardsOnA()
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = #"{"data": {}}"# }
            await model.deleteRow("r1")
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        } }
        await model.loadRows()
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.row(id: "r1") == nil)
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1"))
        #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [[]], "the offline copy")
        await removeCaches()
    }

    /// Table A, then B, then A again (offline, so its saved copy shows) while a delete runs that then fails: the entry
    /// shows once; the saved copy used to bring it back besides the restored one.
    @Test func failedDeleteAfterSwitchingBackShowsTheEntryOnce() async throws {
        let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
        await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
        let session = try await sessionOnA()
        let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
        defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}, {"id": "v2", "name": "B", "type": "table", "position": "b"}]}}"#
        }
        await model.load()
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        await model.loadRows()
        let first = try #require(model.views.first), second = try #require(model.views.last)
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
            await model.select(second)
            StubURLProtocol.offline.withLock { $0 = true }
            await model.select(first)
            StubURLProtocol.offline.withLock { $0 = false }
            // An empty answer isn't JSON, so the delete fails.
            StubURLProtocol.body.withLock { $0 = "" }
        } }
        await model.deleteRow("r1")
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.table.rows.map(\.id) == ["r1"])
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1"))
        #expect(snapshot?.table?.rows.map(\.id) == ["r1"], "the offline copy")
        await removeCaches()
    }

    /// The user edits a card and deletes it before the edit's answer arrives. A delete that fails brings the card back.
    @Test func lateWriteAnswerKeepsTheCardDeleted() async throws {
        let (session, model) = try await boardsOnA()
        StubURLProtocol.offline.withLock { $0 = true }
        await model.deleteRow("r1")
        StubURLProtocol.offline.withLock { $0 = false }
        try #require(model.columns.map { $0.list.rows.map(\.id) } == [["r1"]], "the failed delete")
        StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"t": "x"}}}"# }
        // Tasks on the main actor start in order, so the delete queues behind the edit before its request goes out.
        let editing = Task { await model.setCell(rowId: "r1", propertyId: "t", to: .string("x")) }
        await Task { await model.deleteRow("r1") }.value
        await editing.value
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.columns.map { $0.list.rows.map(\.id) } == [[]] && model.row(id: "r1") == nil)
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1"))
        #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [[]], "the offline copy")
        await removeCaches()
    }

    /// The user edits a card and deletes it before the edit's answer arrives; the edit saves, but the delete fails.
    @Test func failedDeleteKeepsTheCardInTheOfflineCopy() async throws {
        let (session, model) = try await boardsOnA()
        StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"t": "x"}}}"# }
        // The edit's answer still arrives; the delete queued behind it then finds no connection.
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { StubURLProtocol.offline.withLock { $0 = true } } }
        let editing = Task { await model.setCell(rowId: "r1", propertyId: "t", to: .string("x")) }
        await Task { await model.deleteRow("r1") }.value
        await editing.value
        StubURLProtocol.offline.withLock { $0 = false }
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r1"]])
        let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1"))
        #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [["r1"]], "the offline copy")
        await removeCaches()
    }

    /// The user deletes an entry, and a reload and "Load More" answer with it before the server has applied the delete.
    @Test(arguments: ["table", "kanban"]) func lateRowsAnswerKeepsTheEntryDeleted(type: String) async throws {
        let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
        await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
        let session = try await sessionOnA()
        let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
        // A table or a board by "s" (only the "No value" column); the rows request gets the base as its answer too.
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "\#(type)", "config": {"groupByPropertyId": "s"}}]}}"#
        }
        await model.load()
        StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [{"id": "r1", "cells": {}}], "meta": {"hasNextPage": true, "nextCursor": "c"}}}"# }
        await model.loadRows()
        try #require(model.row(id: "r1") != nil)
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            await model.loadRows()
            await model.loadMoreTable()
            await model.loadMore(columnId: BaseKanbanColumn.noValueId)
        } }
        await model.deleteRow("r1")
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(model.row(id: "r1") == nil)
        await removeCaches()
    }

    /// The user changes the query while "Load More" waits, and the new query's results arrive first.
    @Test func lateSearchPageKeepsTheNewQuery() async throws {
        let session = try await sessionOnA()
        let search = SearchModel(query: "a")
        search.session = session
        StubURLProtocol.body.withLock { $0 = Self.results("a1") }
        await search.run()
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
            search.query = "b"
            StubURLProtocol.body.withLock { $0 = Self.results("b1") }
            await search.run()
            StubURLProtocol.body.withLock { $0 = Self.results("a2") }
        } }
        await search.loadMore()
        StubURLProtocol.body.withLock { $0 = nil }
        #expect(search.results.map(\.id) == ["b1"])
        await removeCaches()
    }

    /// Typing on cancels the running search (`.task(id:)`); that must not show "Search failed".
    @Test func cancelledSearchShowsNoError() async throws {
        let session = try await sessionOnA()
        let search = SearchModel(query: "a")
        search.session = session
        let typing = Task { await search.run() }
        StubURLProtocol.beforeNextAnswer.withLock { $0 = { typing.cancel() } }
        await typing.value
        #expect(search.errorMessage == nil)
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

    /// A card dropped on another one lands above it, or below it with `below`, and the board shows the new order
    /// while the move is saved.
    @Test func movedCardLandsBesideItsAnchor() async throws {
        let (session, model) = try await boardsOnA()
        let column = try #require(model.columns.first).id
        func order(afterMoving rowId: String, beside anchorId: String, below: Bool) async -> [String] {
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"items": [{"id": "r1", "cells": {}, "position": "a0"}, {"id": "r2", "cells": {}, "position": "a1"}, {"id": "r3", "cells": {}, "position": "a2"}], "meta": {"hasNextPage": false}}}"#
            }
            await model.loadRows()
            let shown = Mutex<[String]>([])
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                shown.withLock { $0 = model.columns.first?.list.rows.map(\.id) ?? [] }
            } }
            await model.moveCard(rowId, to: column, beside: anchorId, below: below)
            return shown.withLock { $0 }
        }

        #expect(await order(afterMoving: "r3", beside: "r1", below: false) == ["r3", "r1", "r2"])
        #expect(await order(afterMoving: "r1", beside: "r3", below: true) == ["r2", "r3", "r1"])
        #expect(await order(afterMoving: "r3", beside: "r2", below: false) == ["r1", "r3", "r2"])
        StubURLProtocol.body.withLock { $0 = nil }
        // The model holds its session unowned.
        withExtendedLifetime(session) {}
        await removeCaches()
    }

    private static func rows(_ id: String) -> String {
        #"{"data": {"items": [{"id": "\#(id)", "cells": {}}], "meta": {"hasNextPage": false}}}"#
    }

    private static func results(_ id: String) -> String {
        #"{"data": {"items": [{"id": "\#(id)"}]}}"#
    }

    /// Signed in to a, with b saved as well.
    // MARK: - Sign-outs the server didn't get

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

    /// A waiting sign-out whose token expired, or that the server no longer knows (401), is dropped.
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

    // MARK: - Unsent page titles

    /// A title the server didn't get waits on the device and goes out with the first try that reaches the server.
    @Test func keptTitleGoesOutOnceTheServerAnswers() async throws {
        let session = try await sessionOnA()
        defer { UnsentChanges.removeAll(server: a) }
        await session.keepUnsentTitle("Neu", pageId: "p1", spaceId: "s1")

        StubURLProtocol.offline.withLock { $0 = true }
        #expect(await session.sendUnsentTitles().isEmpty)
        StubURLProtocol.offline.withLock { $0 = false }
        #expect(await session.unsentTitle(pageId: "p1") == "Neu")

        StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "p1", "title": "Neu"}}"# }
        defer { StubURLProtocol.body.withLock { $0 = nil } }
        #expect(await session.sendUnsentTitles() == ["s1"])
        #expect(await session.unsentTitle(pageId: "p1") == nil)
        await removeCaches()
    }

    /// A title for a page deleted (or out of reach) meanwhile can never go: it doesn't wait forever.
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
        #expect(await session.sendUnsentTitles().isEmpty)
        #expect(await session.unsentTitle(pageId: "p1") == nil)
        await removeCaches()
    }

    private func sessionOnA() async throws -> AppSession {
        try store.save(StoredSession(serverURL: b, token: "b"))
        try store.save(StoredSession(serverURL: a, token: "a"))
        let session = AppSession(sessionStore: store, protocolClasses: [StubURLProtocol.self])
        await session.restore()
        try #require(session.ready?.server.url == a)
        return session
    }

    /// Signed in to a with a Business license; an editable database with two boards by "s" (no choices, so only the
    /// "No value" column), the first one showing r1.
    private func boardsOnA() async throws -> (AppSession, BaseModel) {
        let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
        await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
        let session = try await sessionOnA()
        let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
        // The rows request gets the base as its answer too, so the rows load again below.
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "kanban", "position": "a", "config": {"groupByPropertyId": "s"}}, {"id": "v2", "name": "B", "type": "kanban", "position": "b", "config": {"groupByPropertyId": "s"}}]}}"#
        }
        await model.load()
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        await model.loadRows()
        try #require(model.columns.map { $0.list.rows.map(\.id) } == [["r1"]])
        return (session, model)
    }

    /// Signed in to a from the offline cache (a start without network), with b saved as well.
    private func offlineSessionOnA() async throws -> AppSession {
        _ = try await sessionOnA()
        StubURLProtocol.offline.withLock { $0 = true }
        let session = AppSession(sessionStore: store, protocolClasses: [StubURLProtocol.self])
        await session.restore()
        StubURLProtocol.offline.withLock { $0 = false }
        try #require(session.ready?.restoredOffline == true)
        return session
    }

    private func removeCaches() async {
        for url in [a, b] { await DiskCache(scope: url.absoluteString).removeAll() }
    }
}

/// `SecretStore` in memory instead of the keychain.
private nonisolated final class MemorySecretStore: SecretStore {
    private let storage = Mutex<[String: Data]>([:])

    func save(_ data: Data, account: String) throws {
        storage.withLock { $0[account] = data }
    }

    func load(account: String) throws -> Data? {
        storage.withLock { $0[account] }
    }

    func delete(account: String) throws {
        storage.withLock { _ = $0.removeValue(forKey: account) }
    }
}

/// Answers every request with the same user (or `body`, with `status`) or fails while `offline`; endpoints expecting
/// something else fall back as on errors. `beforeNextAnswer` runs once while the next request waits (slow network).
private nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let beforeNextAnswer = Mutex<(@Sendable () async -> Void)?>(nil)
    /// Host and path (`a.example.com/api/users/me`) of the request that takes `beforeNextAnswer`; `nil`: the next one.
    /// Taken by any other request (another session's, a background check), the hook delays nothing the test awaits.
    static let beforeNextAnswerFor = Mutex<String?>(nil)
    static let offline = Mutex(false)
    /// How many of the next requests get no answer, as from a server behind a VPN that is off (they wait until cancelled).
    static let unanswered = Mutex(0)
    static let body = Mutex<String?>(nil)
    static let status = Mutex(200)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.offline.withLock({ $0 }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if Self.unanswered.withLock({ count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }) { return }
        let target = (request.url?.host ?? "") + (request.url?.path ?? "")
        let isFor = Self.beforeNextAnswerFor.withLock { $0 }.map { $0 == target } ?? true
        let action = isFor ? Self.beforeNextAnswer.withLock { $0.take() } : nil
        Task {
            await action?()
            let body = Self.body.withLock { $0 } ?? #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}}}"#
            let status = Self.status.withLock { $0 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
