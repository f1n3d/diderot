import Foundation
import Observation
import UIKit
import DocmostKit

enum AppSessionError: LocalizedError {
    case mfaSetupRequired
    case invalidServerURL

    var errorDescription: String? {
        switch self {
        case .mfaSetupRequired:
            return String(localized: "This workspace requires two-factor authentication. Please set it up in the web app first, then sign in again.")
        case .invalidServerURL:
            return String(localized: "Please enter a valid server address.")
        }
    }
}

/// A request of a session that a server switch or sign-out has replaced (`AppSession.perform(on:)`): it didn't go out.
struct SwitchedServer: LocalizedError {
    var errorDescription: String? { String(localized: "Not saved: the app has switched to another server.") }
}

/// Sign-in state machine: `restoring → noServer → signedOut → authenticating → ready` (a restore can skip steps).
/// Back from `ready`: sign-out and 401 to `signedOut`, switching servers to `restoring`, adding one to `noServer`.
@MainActor
@Observable
final class AppSession {
    enum State {
        case restoring
        case noServer
        case signedOut(ServerInfo)
        case authenticating(ServerInfo)
        case ready(ReadySession)
    }

    private(set) var state: State = .restoring {
        didSet {
            // The code step goes with its server's sign-in screen, which stays through its verifying.
            if let uncheckedSignInAfterCode, !isOnSignIn(at: uncheckedSignInAfterCode.serverURL) {
                self.uncheckedSignInAfterCode = nil
            }
            // Only its server's sign-in screen waits for it.
            if case .signedOut(let server) = state, let uncheckedSignIn,
               ServerKey(server.url) == ServerKey(uncheckedSignIn.serverURL) { return }
            uncheckedSignIn = nil
            uncheckedSignInRetry?.cancel()
        }
    }
    /// The saved sign-in the start couldn't check: its server didn't answer, and nothing of it is saved to show. It
    /// stays saved; the sign-in screen says so and tries again, as does the network changing or the app coming back.
    /// The sign-in screen showed without a word, nothing tried again, and signing in anew left its session open.
    private(set) var uncheckedSignIn: StoredSession?
    @ObservationIgnored private var uncheckedSignInRetry: Task<Void, Never>?
    /// `uncheckedSignIn` while the sign-in screen asks for an MFA code, until the code sheet closes (`endMFA`). A retry
    /// meanwhile (the app coming back from the authenticator app) would take over the code step: the sheet went with
    /// the sign-in screen, into the saved sign-in's account.
    @ObservationIgnored private var uncheckedSignInAfterCode: StoredSession?
    /// Saved sign-ins, one per server, including the current one.
    private(set) var accounts: [StoredSession] = []
    private let sessionStore: SessionStore
    private let environment: SessionEnvironment
    private let pendingLogouts: PendingLogouts

    init(sessionStore: SessionStore = SessionStore(), environment: SessionEnvironment = SessionEnvironment()) {
        self.sessionStore = sessionStore
        self.environment = environment
        pendingLogouts = PendingLogouts(store: sessionStore) { environment.makeClient($0, $1) }
    }

    /// How long a start with saved content waits for the server: one that doesn't answer (behind a VPN that is off)
    /// would keep the launch screen up until the requests' timeout (30 s). A page waits as long for the license and
    /// version asked for on returning to the app (`readyOnceAnswered`).
    @ObservationIgnored var startDeadline: Duration = .seconds(5)

    /// How often returning to the app asks for the license and version again (`askLicenseAndVersionIfDue`): Docmost 0.96
    /// and 0.97 ask GitHub at every version request, which allows 60 an hour from one address.
    @ObservationIgnored var licenseAndVersionInterval: Duration = .seconds(15 * 60)
    /// When the current session's license and version were last asked for: at its sign-in, then by
    /// `askLicenseAndVersionIfDue`.
    @ObservationIgnored private var licenseAndVersionAsked: ContinuousClock.Instant?

    var hasAccounts: Bool { !accounts.isEmpty }

    /// Link previews of the signed-in session, made for its token; a new sign-in (or sign-out) starts afresh.
    @ObservationIgnored private var previewStore: (token: String, store: LinkPreviewStore)?
    /// The time zone told to each server while the app runs (`syncTimeZone`).
    @ObservationIgnored private var sentTimeZones: [ServerKey: String] = [:]

    /// The current server's link previews (Docmost 0.97 integration cards and mentions); nil before sign-in.
    var linkPreviews: LinkPreviewStore? {
        guard let ready else {
            previewStore = nil
            return nil
        }
        if let previewStore, previewStore.token == ready.token { return previewStore.store }
        let store = LinkPreviewStore(client: ready.client, cache: ready.cache)
        previewStore = (ready.token, store)
        return store
    }

    func isCurrent(_ account: StoredSession) -> Bool {
        guard let current = server?.url else { return false }
        return ServerKey(account.serverURL) == ServerKey(current)
    }

    private func reloadAccounts() {
        accounts = keychain("load accounts") { try sessionStore.loadAccounts() }?.sessions ?? []
    }

    /// `try?` for a `SessionStore` (keychain) operation, also flattening an optional result, but logging the failure
    /// so an exported log explains a sign-in that wasn't kept.
    @discardableResult
    private func keychain<T>(_ action: String, _ operation: () throws -> T?) -> T? {
        do { return try operation() } catch {
            AppLog.session.error("Keychain \(action, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    var ready: ReadySession? {
        if case .ready(let session) = state { return session }
        return nil
    }

    /// Links open only when signed in or on the sign-in screen (`RootView` keeps them until then): a switch while the
    /// app restores, signs in or checks a new server would be undone by that step's late answer.
    var opensLinks: Bool {
        switch state {
        case .ready, .signedOut: true
        case .restoring, .noServer, .authenticating: false
        }
    }

    /// `false` once a switch or sign-out replaced `session`; a late network answer for it must change nothing.
    func isStillCurrent(_ session: ReadySession) -> Bool {
        guard let ready else { return false }
        return ServerKey(ready.server.url) == ServerKey(session.server.url) && ready.token == session.token
    }

    var client: APIClient? { ready?.client }

    var server: ServerInfo? {
        switch state {
        case .restoring, .noServer: return nil
        case .signedOut(let server), .authenticating(let server): return server
        case .ready(let session): return session.server
        }
    }

    /// Warn when the token expires in under three days (there is no token refresh).
    var tokenExpiresSoon: Bool {
        guard let remaining = ready?.tokenClaims?.remainingLifetime() else { return false }
        return remaining < 3 * 24 * 3600
    }

    // MARK: - Start

    private var launchRestore: Task<Void, Never>?

    /// Every window's root view calls this, but windows share the session: only the first call restores it, in a task
    /// that closing its window can't cancel.
    func restoreAtLaunch() async {
        if launchRestore == nil {
            launchRestore = Task {
                // Before a client downloads: what the last run's left when the app was ended mid-download.
                APIClient.removeAbandonedDownloads()
                TempFile.removeSessionMedia()
                endSignInsOfAnEarlierInstall()
                await restore()
                // Once per launch: a window opened later (iPad) would remove the cookie of an editor open in another.
                await WebEditorStores.removeLeftoverAuthCookies()
            }
        }
        await launchRestore?.value
    }

    /// Set at an install's first start.
    static let installedKey = "installed"

    /// The Keychain keeps sign-ins when the app is deleted, and a reinstall was signed in without a word (code review
    /// R30). At an install's first start, sign-ins saved before its data were created end, as on signing out: an
    /// earlier install's. An update keeps its own, saved since.
    func endSignInsOfAnEarlierInstall(defaults: UserDefaults = .standard, installed: Date? = AppSession.installDate()) {
        guard !defaults.bool(forKey: Self.installedKey) else { return }
        defaults.set(true, forKey: Self.installedKey)
        guard let saved = keychain("check the sign-ins", { try sessionStore.accountsSaved() }), let installed, saved < installed,
              let accounts = keychain("load", { try sessionStore.loadAccounts() })
        else { return }
        AppLog.session.notice("Ending the sign-ins of an earlier install")
        for account in accounts.sessions { keepPendingLogout(account) }
        keychain("remove") { try sessionStore.removeAll() }
    }

    /// When the app's data were created: at its install, kept by updates.
    nonisolated static func installDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: NSHomeDirectory())[.creationDate] as? Date
    }

    /// Restores the saved session, or signs in automatically in debug builds.
    func restore() async {
        reloadAccounts()
        #if DEBUG
        if await applyDebugServerPin() { return }
        #endif
        if let stored = keychain("load", { try sessionStore.load() }) {
            let server = ServerInfo(url: stored.serverURL, workspace: nil)
            if stored.claims?.isExpired() == true {
                AppLog.session.notice("Stored token expired, signing out")
                // Expired by the device's clock, which can run ahead: the server ends it unless it did (`sendPendingLogouts`).
                keepPendingLogout(stored)
                keychain("clear") { try sessionStore.clear() }
                reloadAccounts()
                state = .signedOut(server)
                return
            }
            let client = makeClient(for: stored.serverURL, token: stored.token)
            let hasSavedContent = await makeCache(for: stored.serverURL).read(CurrentUser.self, key: CacheKey.currentUser) != nil
            var answeredLate = false
            do {
                // Without a network (flight mode) the requests can wait for their timeout: start from the cache at once.
                if await environment.hasNoNetwork() { throw APIError.network(URLError(.notConnectedToInternet)) }
                // With saved content to show, a server that doesn't answer in time doesn't keep the start waiting either.
                if try await finishSignIn(server: server, client: client, token: stored.token,
                                          within: hasSavedContent ? startDeadline : nil) { return }
                answeredLate = true
                throw APIError.network(URLError(.timedOut))
            } catch let error as APIError where error.isSessionExpired {
                AppLog.session.notice("Stored session rejected by server, signing out")
                // This sign-in, not the current one: that can have changed during the requests.
                keychain("remove") { try sessionStore.remove(serverURL: stored.serverURL) }
                reloadAccounts()
                state = .signedOut(server)
                return
            } catch {
                // Offline, no answer in time or a server error: continue with the cached user and content.
                let cache = makeCache(for: stored.serverURL)
                if let cachedUser = await cache.read(CurrentUser.self, key: CacheKey.currentUser) {
                    AppLog.session.notice("Server unreachable, restoring session from cache: \(error.userMessage, privacy: .public)")
                    let entitlements = await cache.read(Entitlements.self, key: CacheKey.entitlements) ?? .community
                    let version = await cache.read(String.self, key: CacheKey.serverVersion)
                    state = .ready(ReadySession(
                        server: server, client: client, mediaLoader: MediaLoader(client: client, cache: cache), cache: cache,
                        unsentChanges: environment.makeUnsentStore(server.url, cachedUser.user.id),
                        token: stored.token, currentUser: cachedUser, entitlements: entitlements,
                        serverVersion: Self.reportedVersion(version), restoredOffline: true
                    ))
                    // The sign-in stopped waiting: it goes on in the background, as when the network returns.
                    if answeredLate { Task { await reconnectIfNeeded() } }
                    return
                }
                AppLog.session.error("Could not validate stored session: \(error.userMessage, privacy: .public)")
                state = .signedOut(server)
                uncheckedSignIn = stored
                retryUncheckedSignInWhenTheNetworkChanges()
                return
            }
        }

        #if DEBUG
        if await debugAutoSignIn() { return }
        #endif
        state = .noServer
    }

    // MARK: - Server

    /// Validates the server via `workspace/public` and keeps it for sign-in.
    @discardableResult
    func connect(to input: String) async throws -> ServerInfo {
        guard var url = ServerURLNormalizer.normalize(input) else {
            throw AppSessionError.invalidServerURL
        }
        // A server added before keeps the URL it was added with, however its address is typed now: what the app keeps
        // for it (sign-in, offline copies, unsent changes) is named by that one.
        if let added = accounts.first(where: { ServerKey($0.serverURL) == ServerKey(url) }) { url = added.serverURL }
        let client = makeClient(for: url, token: nil)
        let workspace = try await client.send(Endpoints.Workspace.publicInfo)
        let server = ServerInfo(url: url, workspace: workspace)
        state = .signedOut(server)
        return server
    }

    /// Loads `workspace/public` for a sign-in screen without it (restored session); offline, it stays without.
    func loadWorkspaceInfo() async {
        guard case .signedOut(let server) = state, server.workspace == nil,
              let workspace = try? await makeClient(for: server.url, token: nil).send(Endpoints.Workspace.publicInfo),
              case .signedOut(let current) = state, current == server
        else { return }
        state = .signedOut(ServerInfo(url: server.url, workspace: workspace))
    }

    // MARK: - Multiple servers

    /// Shows server entry (Add Server…, Change Server); saved sign-ins stay and `cancelAddingServer` returns to them.
    func beginAddingServer() {
        state = .noServer
    }

    func cancelAddingServer() async {
        if let accounts = keychain("load accounts", { try sessionStore.loadAccounts() }), accounts.current == nil, let first = accounts.sessions.first {
            keychain("select") { try sessionStore.select(serverURL: first.serverURL) }
        }
        state = .restoring
        await restore()
    }

    /// Switches to a saved sign-in; the previous one stays signed in.
    func switchTo(_ account: StoredSession) async {
        if isCurrent(account), ready != nil { return }
        guard keychain("select", { try sessionStore.select(serverURL: account.serverURL) }) != nil else { return }
        AppLog.session.info("Switching to \(account.serverURL.absoluteString, privacy: .public)")
        LiveDocuments.removeAll()
        state = .restoring
        await restore()
    }

    /// Removes another saved sign-in: ends its server session and deletes its cache and unsent changes.
    func removeAccount(_ account: StoredSession) async {
        guard !isCurrent(account) else { return }
        // As signing out: on the device first, then the server.
        keepPendingLogout(account)
        keychain("remove") { try sessionStore.remove(serverURL: account.serverURL) }
        reloadAccounts()
        UnsentChanges.removeAll(server: account.serverURL)
        await makeCache(for: account.serverURL).removeAll()
        await removeLocalData(for: account.serverURL)
        await sendPendingLogouts()
    }

    /// The saved sign-in whose server matches a web URL (for links to another server).
    func account(matching url: URL) -> StoredSession? {
        guard url.host() != nil else { return nil }
        return accounts.first { Origin($0.serverURL) == Origin(url) }
    }

    // MARK: - Sign in / sign out

    enum SignInOutcome {
        case signedIn
        /// Enterprise MFA: the user still has to enter a code (`completeMFA`).
        case mfaRequired(MFAChallenge)
    }

    /// `server`: the sign-in screen's, for this and the methods below.
    @discardableResult
    func signIn(email: String, password: String, at server: ServerInfo) async throws -> SignInOutcome {
        try await signIn(at: server) { client in
            try await LoginFlow.loginWithPassword(client: client, email: email, password: password)
        }
    }

    @discardableResult
    func signInWithLDAP(providerId: String, username: String, password: String, at server: ServerInfo) async throws -> SignInOutcome {
        try await signIn(at: server) { client in
            try await LoginFlow.loginWithLDAP(client: client, providerId: providerId, username: username, password: password)
        }
    }

    /// Second step after `.mfaRequired`.
    func completeMFA(_ challenge: MFAChallenge, code: String, at server: ServerInfo) async throws {
        try await signIn(at: server, entersCode: true) {
            .authenticated(token: try await LoginFlow.verifyMFA(client: $0, challenge: challenge, code: code))
        }
    }

    /// The MFA code sheet closed (`MFACodeView`): without a sign-in, the screen waits for the saved sign-in the start
    /// couldn't check again (`uncheckedSignInAfterCode`). Closed while a code is verified, that sign-in's failure does.
    func endMFA(at screen: ServerInfo) {
        guard let unchecked = uncheckedSignInAfterCode, ServerKey(unchecked.serverURL) == ServerKey(screen.url) else { return }
        uncheckedSignInAfterCode = nil
        guard case .signedOut(let server) = state, Self.isSameServer(server, as: screen) else { return }
        uncheckedSignIn = unchecked
        retryUncheckedSignInWhenTheNetworkChanges()
    }

    /// Sign-in via the embedded browser (SSO/MFA), which captured the `authToken` cookie.
    func signIn(withToken token: String, at server: ServerInfo) async throws {
        // Before sign-in starts, so an invalid token never shows `.authenticating`.
        guard JWTClaims(token: token)?.isAccessToken == true else {
            throw APIError.unauthorized(message: String(localized: "The browser sign-in did not produce a valid session."))
        }
        do {
            try await signIn(at: server) { _ in .authenticated(token: token) }
        } catch {
            // The browser's session is the app's to end: unused, it stayed valid on the server until it expired
            // (code review R12).
            keepPendingLogout(StoredSession(serverURL: server.url, token: token))
            Task { await sendPendingLogouts() }
            throw error
        }
    }

    /// Signs in to the sign-in screen's server. Once the app shows another (a link switched servers), it doesn't start,
    /// or ends without changing anything (`CancellationError`): the server switched to would get the other's token or
    /// MFA code, and the late answer would sign out of it or replace it. `entersCode`: the MFA code step's (`completeMFA`).
    @discardableResult
    private func signIn(
        at screen: ServerInfo, entersCode: Bool = false, _ login: (APIClient) async throws -> LoginResult
    ) async throws -> SignInOutcome {
        // The state's copy: it can know more of the server (`loadWorkspaceInfo`).
        guard case .signedOut(let server) = state, Self.isSameServer(server, as: screen) else { throw CancellationError() }
        // `.authenticating` ends the wait for the saved sign-in the start couldn't check, so that a late retry can't take
        // over this sign-in. Back on the sign-in screen, it waits for it again. Signing in anew ends a code step.
        let unchecked = uncheckedSignIn ?? uncheckedSignInAfterCode
        if !entersCode { uncheckedSignInAfterCode = nil }
        state = .authenticating(server)
        do {
            let client = makeClient(for: server.url, token: nil)
            switch try await login(client) {
            case .authenticated(let token):
                await client.setToken(token)
                try await finishSignIn(server: server, client: client, token: token, signingIn: true)
                return .signedIn
            case .mfaRequired(let challenge):
                guard isSigningIn(at: server) else { throw CancellationError() }
                // The screen asks for the code (`LoginView`); one that needs MFA set up first says so instead.
                if !challenge.needsSetup { uncheckedSignInAfterCode = unchecked }
                returnToSignIn(at: server, waitingFor: unchecked)
                return .mfaRequired(challenge)
            }
        } catch {
            if isSigningIn(at: server) { returnToSignIn(at: server, waitingFor: unchecked) }
            throw error
        }
    }

    /// The sign-in screen again after a sign-in that didn't finish, with the saved sign-in it waited for
    /// (`uncheckedSignIn`): Try Again went, and nothing checked the saved sign-in again until a relaunch. While it asks
    /// for an MFA code, that waits for the code sheet to close (`endMFA`).
    private func returnToSignIn(at server: ServerInfo, waitingFor unchecked: StoredSession?) {
        state = .signedOut(server)
        guard let unchecked, uncheckedSignInAfterCode == nil else { return }
        uncheckedSignIn = unchecked
        retryUncheckedSignInWhenTheNetworkChanges()
    }

    private func isSigningIn(at server: ServerInfo) -> Bool {
        guard case .authenticating(let current) = state else { return false }
        return Self.isSameServer(current, as: server)
    }

    /// The server's sign-in screen shows, signing in or not.
    private func isOnSignIn(at serverURL: URL) -> Bool {
        switch state {
        case .signedOut(let current), .authenticating(let current): ServerKey(current.url) == ServerKey(serverURL)
        case .restoring, .noServer, .ready: false
        }
    }

    private static func isSameServer(_ server: ServerInfo, as other: ServerInfo) -> Bool {
        ServerKey(server.url) == ServerKey(other.url)
    }

    /// Signs out of the current server and continues with another saved one, if any.
    func signOut() async {
        guard case .ready(let session) = state else { return }
        // On the device before any await: the server can take its 30 s to answer (behind a VPN that is off), and an app
        // left meanwhile stayed signed in. A reconnect finishing meanwhile is no longer current, so it can't save the
        // session again. The server's session ends through the waiting sign-outs, which retry until it answers.
        keepPendingLogout(StoredSession(serverURL: session.server.url, token: session.token))
        keychain("remove") { try sessionStore.remove(serverURL: session.server.url) }
        reloadAccounts()
        AppLog.session.info("Signed out")
        LiveDocuments.removeAll()
        let next = nextAccountAfterSignOut()
        state = next == nil ? .signedOut(session.server) : .restoring
        await removeLocalData(for: session.server.url)
        if let next, case .restoring = state { await switchTo(next) }
        await sendPendingLogouts()
    }

    // MARK: - Sign-outs the server didn't get

    /// A sign-out for its server: `sendPendingLogouts` ends the session there, now or once the server answers; out of
    /// reach, it would stay valid there until it expires.
    private func keepPendingLogout(_ session: StoredSession) {
        keychain("keep the sign-out") { try pendingLogouts.keep(session) }
    }

    /// Ends the sessions signed out while their server was out of reach (`signOut`): at launch, back in the app and when
    /// the network returns. A token the server no longer knows (401), or that expired a week ago, is dropped.
    func sendPendingLogouts() async {
        do { try await pendingLogouts.send() } catch {
            AppLog.session.error("Keychain update the waiting sign-outs failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Unsent page titles and database fields

    @ObservationIgnored private let unsentEdits = UnsentEdits()

    /// Keeps a page title the server didn't get; `sendUnsentTitles` sends it once the server answers. False if it couldn't
    /// be kept: then nothing may promise it a later try (`UnsentEdits.keepTitle`).
    /// `store`: the unsent changes of the session the page was opened in, as the editor engine keeps its own; a 401 or a
    /// switch may have ended that session meanwhile. Without one, the current session's.
    @discardableResult
    func keepUnsentTitle(_ title: String, pageId: String, spaceId: String?, in store: UnsentStore? = nil) async -> Bool {
        guard let store = store ?? ready?.unsentChanges else { return false }
        return await UnsentEdits.keepTitle(title, pageId: pageId, spaceId: spaceId, in: store)
    }

    /// The page's kept title, if it still waits for the server. `store`: the one it was kept in; without one, the
    /// current session's.
    func unsentTitle(pageId: String, in store: UnsentStore? = nil) async -> String? {
        guard let store = store ?? ready?.unsentChanges else { return nil }
        return await UnsentEdits.title(pageId: pageId, in: store)
    }

    /// Drops the page's kept title: it, or a newer one, reached the server. With `title`, only while it is still that one.
    /// `store`: the one it was kept in (the page's session's); the current session's may be another server's by now.
    func forgetUnsentTitle(pageId: String, title: String? = nil, in store: UnsentStore? = nil) async {
        guard let store = store ?? ready?.unsentChanges else { return }
        await UnsentEdits.forgetTitle(pageId: pageId, title: title, in: store)
    }

    /// Sends the kept titles (`UnsentEdits.sendTitles`). Returns the spaces whose pages got theirs, and the titles that
    /// can never go, which it dropped; after another error the rest waits for the next try (going online, back in the
    /// app, opening a page). A rename takes a verified or approved page's verification back (Docmost 0.98, license
    /// feature `page:verification`), so such a page's title waits for "Edit" on the page, as its text does: `consented`
    /// holds the lock the person chose to edit a page through.
    func sendUnsentTitles(consented: [String: PageVerification.Lock] = [:]) async -> (spaces: [String], dropped: [UnsentEdits.DroppedChange]) {
        guard let session = ready else { return ([], []) }
        // Decided at the first kept title: only a title to send waits for the license and version.
        var checksVerification: Bool?
        return await unsentEdits.sendTitles(in: session.unsentChanges) { pageId, title in
            if checksVerification == nil { checksVerification = await checksVerificationOnceAnswered(on: session) }
            if checksVerification == true, let lock = try await verificationLock(of: pageId, on: session), consented[pageId] != lock {
                throw UnsentEdits.WaitsForEdit()
            }
            // Another account's pages don't exist on its server: after a switch nothing more goes out.
            _ = try await send(Endpoints.Pages.update(pageId: pageId, title: title), on: session)
        }
    }

    /// Whether `session`'s kept titles wait for "Edit" on verified pages (`PageLoader.checksVerification`), by the license
    /// and version that returning to the app or the network asks for (`askLicenseAndVersionIfDue`), whether that question
    /// runs already or is due: the app's return sends kept titles while it asks, and a Docmost upgrade or a license
    /// change found then turns the check on. False once a switch or sign-out ended `session`: nothing of it goes out then.
    private func checksVerificationOnceAnswered(on session: ReadySession) async -> Bool {
        // An offline session's are asked for when it reconnects (`finishSignIn`).
        if !session.restoredOffline { await askLicenseAndVersionIfDue(of: session)?.value }
        guard isStillCurrent(session), let current = ready else { return false }
        return PageLoader.checksVerification(on: current)
    }

    /// The current session; while returning to the app or the network asks for the license and version
    /// (`askLicenseAndVersionIfDue`), once they have come. A page loading meanwhile builds its editor by them
    /// (`PageView.load`): an engine reads only when it opens whether it holds its changes for the page's verification,
    /// so one built from the session as it was never held, and its kept changes took a verification back on the return
    /// that first found Docmost 0.98 with `page:verification`. At once where no question runs: it starts none. At most
    /// `startDeadline`: a server that doesn't answer (behind a VPN that is off) would keep the page empty until the
    /// requests' timeout (30 s), and its editor can't connect to it either.
    func readyOnceAnswered() async -> ReadySession? {
        if let asking = askingLicenseAndVersion, isStillCurrent(asking.session) {
            let deadline = startDeadline
            let (over, end) = AsyncStream<Void>.makeStream()
            // Unstructured: waiting for the question's task doesn't end when cancelled, so a task group would wait it out.
            Task { await asking.task.value; end.finish() }
            let timeout = Task { try? await Task.sleep(for: deadline); end.finish() }
            for await _ in over {}
            timeout.cancel()
        }
        return ready
    }

    /// The page's lock (`PageVerification.lock`) as the server says it now; nil without one, also where the server has
    /// no enterprise code (404).
    private func verificationLock(of pageId: String, on session: ReadySession) async throws -> PageVerification.Lock? {
        do {
            return try await send(Endpoints.Pages.verificationInfo(pageId: pageId), on: session).lock
        } catch APIError.notFound {
            return nil
        }
    }

    /// Sends the kept database fields (`UnsentCell`), as `sendUnsentTitles` does titles. Returns the ones that can never
    /// go (entry deleted, access gone, value refused), which it dropped.
    func sendUnsentCells() async -> [UnsentEdits.DroppedChange] {
        guard let session = ready else { return [] }
        return await unsentEdits.sendCells(in: session.unsentChanges) { cell in
            _ = try await send(Endpoints.Bases.updateRow(pageId: cell.basePageId, rowId: cell.rowId, cells: [cell.propertyId: cell.value]),
                               on: session)
        }
    }

    /// Runs an API call of the session current now and ends that session on 401. Private: a caller's client of an earlier
    /// session would have its 401 blamed on this one (a list of a signed-out server signing out the next); a flow binds
    /// its session once (`perform(on:)`, `load(_:of:)`).
    private func perform<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        let session = ready
        do {
            return try await operation()
        } catch let error as APIError where error.isSessionExpired {
            if let session, isStillCurrent(session) { handleUnauthorized() }
            throw error
        }
    }

    /// One request through `perform`. Without a session it throws `CancellationError`: the asking screen is closing.
    func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        guard let client else { throw CancellationError() }
        return try await perform { try await client.send(endpoint) }
    }

    /// Runs requests with `owner`'s client, for work bound to the session it started in: a flow's later requests, or
    /// content that belongs to that server. Once a switch or sign-out has replaced `owner`, nothing goes out
    /// (`SwitchedServer`): the new server would get the content. A 401 ends only `owner`.
    func perform<T: Sendable>(on owner: ReadySession, _ operation: (APIClient) async throws -> T) async throws -> T {
        guard isStillCurrent(owner) else { throw SwitchedServer() }
        do {
            return try await operation(owner.client)
        } catch let error as APIError where error.isSessionExpired {
            if isStillCurrent(owner) { handleUnauthorized() }
            throw error
        }
    }

    /// One request through `perform(on:)`.
    func send<Response>(_ endpoint: Endpoint<Response>, on owner: ReadySession) async throws -> Response {
        try await perform(on: owner) { try await $0.send(endpoint) }
    }

    /// `send(_:on:)` for what a screen shows from `owner`'s server (a list, a page): once a switch or sign-out has replaced
    /// `owner`, nothing goes out and it ends as the closing screen's request does (`CancellationError`), without a word.
    func load<Response>(_ endpoint: Endpoint<Response>, of owner: ReadySession) async throws -> Response {
        do {
            return try await send(endpoint, on: owner)
        } catch is SwitchedServer {
            throw CancellationError()
        }
    }

    /// Handles a 401. Idempotent: concurrent 401s trigger only one transition.
    func handleUnauthorized() {
        guard case .ready(let session) = state else { return }
        AppLog.session.notice("Session rejected (401), returning to sign-in")
        keychain("remove") { try sessionStore.remove(serverURL: session.server.url) }
        reloadAccounts()
        state = .signedOut(session.server)
    }

    /// Revalidates the session when the app returns to the foreground or the network returns, and every
    /// `licenseAndVersionInterval` its license and version too (`askLicenseAndVersionIfDue`).
    func refreshCurrentUser() async {
        guard case .ready(let session) = state else { return }
        if session.restoredOffline {
            await reconnectIfNeeded()
            return
        }
        let licenseAndVersion = askLicenseAndVersionIfDue(of: session)
        do {
            let user = try await session.client.send(Endpoints.Users.me)
            // First: the time zone below goes only to Docmost 0.98, which the answer may have just named.
            await licenseAndVersion?.value
            // The current state, not `session`: switching servers and back meanwhile replaced the client and cache.
            guard isStillCurrent(session), case .ready(var current) = state else { return }
            // Usually unchanged: writing `state` anyway would rebuild every view that reads the session.
            if user != current.currentUser {
                current.currentUser = user
                state = .ready(current)
            }
            // Also when unchanged: an offline start needs it, and iOS may have purged the cache meanwhile.
            await current.cache.write(user, key: CacheKey.currentUser)
            // Back in the app, perhaps in another time zone.
            await syncTimeZone(of: current)
        } catch let error as APIError where error.isSessionExpired {
            if isStillCurrent(session) { handleUnauthorized() }
        } catch {
            AppLog.session.debug("Refresh skipped: \(error.userMessage, privacy: .public)")
            // After its question here too: the next return then knows whether it counted as asked.
            await licenseAndVersion?.value
        }
    }

    /// The running question for the license and version (`askLicenseAndVersionIfDue`): its session, when it was asked.
    @ObservationIgnored private var askingLicenseAndVersion: (session: ReadySession, asked: ContinuousClock.Instant, task: Task<Void, Never>)?

    /// Asks `session`'s server for its license and version once `licenseAndVersionInterval` has passed since they were
    /// last asked for, and writes what changed: iOS may keep the app in memory for days, across a Docmost upgrade or a
    /// license change, and both decide whether verified pages ask before an edit and whether pages open read-only. Back
    /// in the app or the network (`refreshCurrentUser`) and before kept titles go (`sendUnsentTitles`), whichever comes
    /// first; while it runs, later callers get the running one to wait for. Nil where none is due.
    private func askLicenseAndVersionIfDue(of session: ReadySession) -> Task<Void, Never>? {
        if let asking = askingLicenseAndVersion, isStillCurrent(asking.session) { return asking.task }
        guard licenseAndVersionAsked.map({ $0.duration(to: .now) >= licenseAndVersionInterval }) ?? true else { return nil }
        // Taken before the requests go out: the windows of an iPad that come back together ask once.
        let previous = licenseAndVersionAsked, asked = ContinuousClock.now
        licenseAndVersionAsked = asked
        let task = Task {
            defer { if askingLicenseAndVersion?.asked == asked { askingLicenseAndVersion = nil } }
            let (entitlements, version) = await Self.licenseAndVersion(from: session.client)
            guard entitlements != nil || version != nil else {
                // Without network yet, nothing reached the server, nor GitHub: the next return asks again, unless a sign-in
                // asked meanwhile.
                if licenseAndVersionAsked == asked { licenseAndVersionAsked = previous }
                return
            }
            // The current state, not `session`: switching servers and back meanwhile replaced the client and cache.
            guard isStillCurrent(session), case .ready(var current) = state else { return }
            // Usually unchanged: writing `state` anyway would rebuild every view that reads the session. An answer that
            // didn't come keeps what is known, as at sign-in.
            var changed = false
            if let entitlements, entitlements != current.entitlements {
                current.entitlements = entitlements
                changed = true
            }
            if let version, Self.reportedVersion(version) != current.serverVersion {
                current.serverVersion = Self.reportedVersion(version)
                changed = true
            }
            if changed { state = .ready(current) }
            // Also when unchanged: an offline start needs them, and iOS may have purged the cache meanwhile.
            if let entitlements { await current.cache.write(entitlements, key: CacheKey.entitlements) }
            if let version { await current.cache.write(version, key: CacheKey.serverVersion) }
        }
        askingLicenseAndVersion = (session, asked, task)
        return task
    }

    /// The server's license and the version it names, each nil where it didn't come (`finishSignIn` says why).
    private static func licenseAndVersion(from client: APIClient) async -> (Entitlements?, String?) {
        async let entitlements = client.send(Endpoints.Workspace.entitlements)
        async let version = client.send(Endpoints.Version.info)
        return (try? await entitlements, (try? await version)?.currentVersion)
    }

    /// Clears the current server's offline cache, except the user, license and version that an offline start restores.
    func clearCache() async {
        guard let ready else { return }
        let version = await ready.cache.read(String.self, key: CacheKey.serverVersion)
        await ready.cache.removeAll()
        await ready.cache.write(ready.currentUser, key: CacheKey.currentUser)
        await ready.cache.write(ready.entitlements, key: CacheKey.entitlements)
        if let version { await ready.cache.write(version, key: CacheKey.serverVersion) }
        // Not its staged uploads: a running upload reads them. Nor the web editor's edits the server doesn't have yet.
        await removeLocalData(for: ready.server.url, LocalDataRemoval(uploads: false, webStorage: false))
    }

    /// Whether the signed-out server keeps its offline copies from before: for the same person when they sign in again.
    func hasSavedContent(of server: ServerInfo) async -> Bool {
        await makeCache(for: server.url).totalSize() > 0
    }

    /// Removes the offline copies and files the signed-out server's sign-in left, on its sign-in screen: once signed
    /// out, the server was in no list where they could be removed, as the privacy policy says they can (code review R16).
    /// Not its changes the server doesn't have yet: they go out at the next sign-in there. The web editor's go with
    /// signing out (R24); after a 401 they are still there, and stay.
    func clearSavedContent(of server: ServerInfo) async {
        guard case .signedOut(let current) = state, Self.isSameServer(current, as: server) else { return }
        await makeCache(for: server.url).removeAll()
        await removeLocalData(for: server.url, .savedContent)
    }

    // MARK: - Internal

    /// `replacing`: the offline session that a reconnect loads fully. `signingIn`: a sign-in from the sign-in screen.
    /// `retrying`: the unchecked sign-in, tried again (`retryUncheckedSignIn`).
    private func finishSignIn(
        server: ServerInfo, client: APIClient, token: String, replacing: ReadySession? = nil, signingIn: Bool = false,
        retrying: StoredSession? = nil
    ) async throws {
        async let me = client.send(Endpoints.Users.me)
        async let entitlements = client.send(Endpoints.Workspace.entitlements)
        async let version = client.send(Endpoints.Version.info)
        let currentUser = try await me

        var server = server
        if server.workspace == nil {
            server.workspace = try? await client.send(Endpoints.Workspace.publicInfo)
        }
        let answeredEntitlements: Entitlements?
        do {
            answeredEntitlements = try await entitlements
        } catch {
            AppLog.session.error("Entitlements unavailable, using cached: \(error.userMessage, privacy: .public)")
            answeredEntitlements = nil
        }
        let namedVersion = (try? await version)?.currentVersion
        // Nothing is written before every answer is in and the sign-in still counts: storing another user empties the
        // cache and removes the local data, the web editor's unsynced edits too, and a late answer did that to the
        // session that took over meanwhile. No await between the check and `storeCurrentUser`.
        guard try stillCounts(replacing: replacing, signingIn: signingIn, at: server, retrying: retrying) else { return }
        let cache = makeCache(for: server.url)
        if await Self.storeCurrentUser(currentUser, in: cache) {
            await removeLocalData(for: server.url)
        }
        // Every edition answers this, so a failure is a hiccup: keep the last known license (from this user's cache,
        // hence after `storeCurrentUser`).
        let resolvedEntitlements: Entitlements
        if let answeredEntitlements {
            resolvedEntitlements = answeredEntitlements
            await cache.write(answeredEntitlements, key: CacheKey.entitlements)
        } else {
            resolvedEntitlements = await cache.read(Entitlements.self, key: CacheKey.entitlements) ?? .community
        }
        // Docmost names its version only after asking GitHub for its latest release, and nothing when GitHub refuses
        // (60 requests an hour from one address) or a proxy blocks it: keep the last one it named.
        let serverVersion: String?
        if let namedVersion {
            serverVersion = namedVersion
            await cache.write(namedVersion, key: CacheKey.serverVersion)
        } else {
            serverVersion = await cache.read(String.self, key: CacheKey.serverVersion)
        }
        // Again after the cache writes' awaits; from here no await until the `state` write.
        guard try stillCounts(replacing: replacing, signingIn: signingIn, at: server, retrying: retrying) else { return }
        let stored = StoredSession(serverURL: server.url, token: token, email: currentUser.user.email, workspaceName: currentUser.workspace.name)
        // A sign-in anew replaces the server's saved one (one per server): its session ends on the server, as on
        // signing out, instead of staying open.
        if let replaced = accounts.first(where: { ServerKey($0.serverURL) == ServerKey(server.url) }),
           replaced.token != token {
            keepPendingLogout(replaced)
        }
        keychain("save") { try sessionStore.save(stored) }
        reloadAccounts()
        // Not what an offline start reads: a license or version kept from an earlier answer can be older than every photo.
        // While the app runs, the media loader caps the cache again.
        Task.detached(priority: .utility) { await cache.prune(keeping: CacheKey.offlineStart) }
        // Just asked for: returning to the app asks again only after `licenseAndVersionInterval`.
        licenseAndVersionAsked = .now
        state = .ready(ReadySession(
            server: server, client: client, mediaLoader: MediaLoader(client: client, cache: cache), cache: cache,
            unsentChanges: environment.makeUnsentStore(server.url, currentUser.user.id),
            token: token, currentUser: currentUser, entitlements: resolvedEntitlements,
            serverVersion: Self.reportedVersion(serverVersion)
        ))
        AppLog.session.info("Signed in as \(currentUser.user.email, privacy: .private) at \(server.url.absoluteString, privacy: .public)")
        if case .ready(let ready) = state { Task { await syncTimeZone(of: ready) } }
    }

    /// Whether `finishSignIn`'s answers still count. A reconnect must not undo a switch or sign-out made meanwhile, nor
    /// replace a session loaded fully meanwhile, by switching away and back (`false`: it ends without a word); a sign-in
    /// must not undo a switch, and a retry of the unchecked sign-in not a sign-in anew or a switch (`CancellationError`).
    private func stillCounts(
        replacing: ReadySession?, signingIn: Bool, at server: ServerInfo, retrying: StoredSession?
    ) throws -> Bool {
        // Server and token stay the same when switching back: only the offline session is still to replace.
        if let replacing, !isStillCurrent(replacing) || ready?.restoredOffline != true { return false }
        if signingIn, !isSigningIn(at: server) { throw CancellationError() }
        if let retrying, uncheckedSignIn != retrying { throw CancellationError() }
        return true
    }

    /// Tells a Docmost 0.98 server the device's time zone where it keeps another one or none, as the web does once a load
    /// (`use-sync-user-timezone.ts`); once a zone per server while the app runs, and without a word where it fails, as
    /// there. 0.98 keeps it with the user; older servers know none.
    func syncTimeZone(of session: ReadySession, zone: TimeZone = .current) async {
        let key = ServerKey(session.server.url)
        guard session.hasDocmost098Features, !zone.identifier.isEmpty, session.currentUser.user.timezone != zone.identifier,
              sentTimeZones[key] != zone.identifier else { return }
        sentTimeZones[key] = zone.identifier
        do {
            _ = try await session.client.send(Endpoints.Users.update(timezone: zone.identifier))
        } catch {
            sentTimeZones[key] = nil
            AppLog.session.debug("Time zone not sent: \(error.userMessage, privacy: .public)")
        }
    }

    /// `finishSignIn`, given up after `deadline` (`nil`: as long as the requests take): `false` if it was.
    private func finishSignIn(server: ServerInfo, client: APIClient, token: String, within deadline: Duration?) async throws -> Bool {
        guard let deadline else {
            try await finishSignIn(server: server, client: client, token: token)
            return true
        }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await self.finishSignIn(server: server, client: client, token: token); return true }
            group.addTask { try await Task.sleep(for: deadline); return false }
            let signedIn = try await group.next() == true
            // The group waits for both: a sleep left running used to hold every answered start until the deadline.
            group.cancelAll()
            if signedIn { return true }
            // Done right before the cancel: then it counts.
            return (try? await group.next()) == true
        }
    }

    private func makeClient(for url: URL, token: String?) -> APIClient {
        environment.makeClient(url, token)
    }

    private func makeCache(for url: URL) -> DiskCache {
        environment.makeCache(url)
    }

    /// Writes the user to the per-server offline cache. If another user (or workspace) was cached, it clears the cache
    /// first and returns `true`, so their other local data goes too. The same user keeps it across sign-out and expiry;
    /// an unknown previous user (iOS purged the cache) counts as the same, so the web editor keeps unsynced edits.
    static func storeCurrentUser(_ user: CurrentUser, in cache: DiskCache) async -> Bool {
        let cached = await cache.read(CurrentUser.self, key: CacheKey.currentUser)
        let isOtherUser = cached.map { $0.user.id != user.user.id || $0.workspace.id != user.workspace.id } ?? false
        if isOtherUser {
            await cache.removeAll()
        }
        await cache.write(user, key: CacheKey.currentUser)
        return isOtherUser
    }

    /// Removes what the offline cache doesn't cover (`SessionEnvironment.removeLocalData`).
    private func removeLocalData(for serverURL: URL, _ removal: LocalDataRemoval = .all) async {
        await environment.removeLocalData(serverURL, removal)
    }

    /// Checks the saved sign-in the start couldn't check (`uncheckedSignIn`) again. Its result counts only while the
    /// sign-in screen still waits for it: signing in or switching servers meanwhile wins.
    func retryUncheckedSignIn() async {
        guard let unchecked = uncheckedSignIn, case .signedOut(let server) = state else { return }
        do {
            try await finishSignIn(server: server, client: makeClient(for: unchecked.serverURL, token: unchecked.token),
                                   token: unchecked.token, retrying: unchecked)
        } catch let error as APIError where error.isSessionExpired {
            // Ended on the server meanwhile: it goes, as at the start.
            guard uncheckedSignIn == unchecked else { return }
            AppLog.session.notice("Stored session rejected by server, signing out")
            keychain("remove") { try sessionStore.remove(serverURL: unchecked.serverURL) }
            reloadAccounts()
            uncheckedSignIn = nil
            uncheckedSignInRetry?.cancel()
        } catch {
            guard uncheckedSignIn == unchecked else { return }
            AppLog.session.notice("Saved sign-in still unchecked: \(error.userMessage, privacy: .public)")
            retryUncheckedSignInWhenTheNetworkChanges()
        }
    }

    /// Once the network changes (a VPN coming on, another Wi-Fi), not for the network as it is now: a server that
    /// doesn't answer on it would be asked again and again.
    private func retryUncheckedSignInWhenTheNetworkChanges() {
        uncheckedSignInRetry?.cancel()
        uncheckedSignInRetry = Task { [weak self, environment] in
            guard await environment.networkReturns() else { return }
            await self?.retryUncheckedSignIn()
        }
    }

    /// How long after a reconnect starts a call waits for it instead of starting its own (`reconnectIfNeeded`): enough
    /// for the calls of one moment, from the network returning and the app coming back, in every window.
    @ObservationIgnored var reconnectJoinWindow: Duration = .seconds(2)

    /// The running reconnect, the offline session it loads and when it started.
    @ObservationIgnored
    private var reconnecting: (session: ReadySession, task: Task<Void, Never>, started: ContinuousClock.Instant)?

    /// After an offline start, fully loads the session once the server is reachable again. The network returning and the
    /// app coming back call this together, in every window: a call moments after a reconnect of the session started
    /// waits for that one instead of checking the sign-in again. If that one fails, the calls that waited try once
    /// more, together. A later call starts its own: what it answers, such as a VPN coming on, which changes no network
    /// status (`OfflineMonitor`), came after the running one's requests, which can wait for their timeout (30 s)
    /// without the VPN. Of two that run, the one that ends last writes nothing (`stillCounts`).
    func reconnectIfNeeded() async {
        guard case .ready(let session) = state, session.restoredOffline else { return }
        guard let running = joinableReconnect else { return await reconnect(session) }
        await running.value
        guard case .ready(let current) = state, current.restoredOffline, isStillCurrent(session) else { return }
        // The first of them to go on starts it; the others wait for that one.
        if let next = joinableReconnect, next != running { return await next.value }
        await reconnect(current)
    }

    /// The running reconnect if it loads the current session and started moments ago (`reconnectJoinWindow`).
    private var joinableReconnect: Task<Void, Never>? {
        guard let reconnecting, isStillCurrent(reconnecting.session),
              reconnecting.started.duration(to: .now) < reconnectJoinWindow else { return nil }
        return reconnecting.task
    }

    /// Fully loads the offline session, in a task that later calls wait for (`reconnectIfNeeded`).
    private func reconnect(_ session: ReadySession) async {
        let task = Task {
            do {
                try await finishSignIn(server: session.server, client: session.client, token: session.token, replacing: session)
            } catch let error as APIError where error.isSessionExpired {
                if isStillCurrent(session) { handleUnauthorized() }
            } catch {
                AppLog.session.debug("Still offline: \(error.userMessage, privacy: .public)")
            }
        }
        reconnecting = (session, task, .now)
        await task.value
        // Unless another reconnect took its place: the next session's, after a switch and another offline start, one
        // that a later call started while this one ran, or the one that the calls that waited for this one start when
        // it failed.
        if reconnecting?.task == task { reconnecting = nil }
    }

    /// Names the app (not Docmost: it isn't Docmost's app); the server derives the device name for its session list
    /// from the rest ("iPhone", "iPad").
    static let userAgent: String = {
        let device = UIDevice.current
        let version = device.systemVersion.replacingOccurrences(of: ".", with: "_")
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "Diderot/\(appVersion) (\(device.model); CPU iPhone OS \(version) like Mac OS X) DocmostKit/\(DocmostKitInfo.version)"
    }()

    private func nextAccountAfterSignOut() -> StoredSession? {
        #if DEBUG
        if let pinned = Self.debugServerURL, let account = account(matching: pinned) { return account }
        #endif
        return accounts.first
    }

    /// The server's version, or the one a debug launch gives in its place (`DOCMOST_DEBUG_SERVER_VERSION`).
    private static func reportedVersion(_ version: String?) -> String? {
        #if DEBUG
        DebugLaunch.serverVersion ?? version
        #else
        version
        #endif
    }

    #if DEBUG
    private var debugPinApplied = false

    private static var debugServerURL: URL? { DebugLaunch.server.flatMap(ServerURLNormalizer.normalize) }

    /// Debug launch with a test server (`DOCMOST_DEBUG_SERVER`): the first restore uses it even if another saved
    /// server (e.g. production) was last active, so UI tests and debug hooks never hit another instance; later
    /// switches (`ServerUITests`) still work. Returns `true` once it connected the debug server, even if sign-in fails.
    private func applyDebugServerPin() async -> Bool {
        guard !debugPinApplied else { return false }
        debugPinApplied = true
        guard let pinned = Self.debugServerURL else { return false }
        if let account = account(matching: pinned) {
            let current = keychain("load", { try sessionStore.load() }).map { ServerKey($0.serverURL) }
            if current != ServerKey(account.serverURL) {
                AppLog.session.notice("Debug server pin: switching to \(account.serverURL.absoluteString, privacy: .public)")
                keychain("select") { try sessionStore.select(serverURL: account.serverURL) }
            }
            // Expired (a test device unused for weeks): sign in again instead of stopping at the sign-in screen.
            // Unreachable: `restore` then shows this server's sign-in screen.
            guard account.claims?.isExpired() == true else { return false }
            AppLog.session.notice("Debug server pin: sign-in expired, signing in again")
            return await debugAutoSignIn()
        }
        // No sign-in for the debug server yet: don't restore the other server's saved session, not even when the
        // debug server is unreachable.
        guard keychain("load", { try sessionStore.load() }) != nil else { return false }
        AppLog.session.notice("Debug server pin: signing in to \(pinned.absoluteString, privacy: .public)")
        if await !debugAutoSignIn() { state = .signedOut(ServerInfo(url: pinned, workspace: nil)) }
        return true
    }

    /// Automatic sign-in from the launch environment (`Tools/run-sim.sh`). Returns `true` once the server is connected,
    /// even if sign-in fails (the app then stays on the sign-in screen).
    private func debugAutoSignIn() async -> Bool {
        guard let serverText = DebugLaunch.server else { return false }
        let server: ServerInfo
        do {
            server = try await connect(to: serverText)
        } catch {
            AppLog.session.error("Debug server not reachable: \(error.userMessage, privacy: .public)")
            return false
        }
        guard let email = DebugLaunch.email, let password = DebugLaunch.password, !DebugLaunch.browserLogin
        else { return true }
        do {
            try await signIn(email: email, password: password, at: server)
            AppLog.session.notice("Debug auto sign-in succeeded")
        } catch {
            AppLog.session.error("Debug auto sign-in failed: \(error.userMessage, privacy: .public)")
        }
        return true
    }
    #endif
}
