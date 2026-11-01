import Foundation
import Network
import Observation
import UIKit
import DocmostKit

/// The server in use, before and after sign-in.
struct ServerInfo: Hashable, Sendable {
    var url: URL
    var workspace: PublicWorkspace?

    var displayName: String { workspace?.name ?? url.host() ?? url.absoluteString }
}

/// Signed-in session.
struct ReadySession: Sendable {
    let server: ServerInfo
    let client: APIClient
    let imageLoader: ImageLoader
    /// Offline cache for this server's lists, pages and images.
    let cache: DiskCache
    /// Access token, e.g. for WebViews that need the `authToken` cookie.
    let token: String
    var currentUser: CurrentUser
    var entitlements: Entitlements
    /// Docmost version, else the last one this server told; nil if never known (Docmost Cloud, the server's GitHub check
    /// failing or taking too long since the first sign-in).
    var serverVersion: String?
    var tokenClaims: JWTClaims? { JWTClaims(token: token) }
    /// Restored from the cache without reaching the server.
    var restoredOffline = false

    /// This user's changes the server hasn't confirmed yet.
    var unsentChanges: DiskCache { UnsentChanges.store(server: server.url, userId: currentUser.user.id) }

    /// The server's version if it is newer than the bundled editor's (Docmost 0.97, `Engine/`), which could damage
    /// content it doesn't know: pages there open read-only. An unknown version counts as supported.
    var newerServerVersion: String? { Self.isNewerThanEditor(serverVersion) ? serverVersion : nil }

    /// Docmost 0.97 or newer: tabs, integration links and sorted sub-pages can be added. An unknown version doesn't
    /// count: on an older server they would get lost.
    var hasDocmost097Features: Bool { Self.supportsDocmost097(serverVersion) }

    static func supportsDocmost097(_ version: String?) -> Bool {
        majorMinor(version).map { $0 >= (0, 97) } ?? false
    }

    static func isNewerThanEditor(_ version: String?) -> Bool {
        majorMinor(version).map { $0 > (0, 97) } ?? false
    }

    private static func majorMinor(_ version: String?) -> (Int, Int)? {
        let parts = version?.trimmingPrefix("v").split(separator: ".").prefix(2).map { Int($0.prefix(while: \.isNumber)) }
        guard let parts, parts.count == 2, let major = parts[0], let minor = parts[1] else { return nil }
        return (major, minor)
    }
}

enum CacheKey {
    static let currentUser = "users/me"
    static let entitlements = "workspace/entitlements"
    /// The server's last known Docmost version.
    static let serverVersion = "version"
    static let spaces = "spaces"
    static let recent = "pages/recent"
    static let favorites = "favorites"
    static let recentlyOpened = "recentlyOpened"
    static func page(_ id: String) -> String { "page/\(id)" }
    /// Yjs state with changes the server hadn't confirmed when the page closed (in `UnsentChanges`).
    static func unsentChanges(_ pageId: String) -> String { "unsent/\(pageId)" }
    /// The document with them, shown while offline.
    static func unsentDocument(_ pageId: String) -> String { "unsentDocument/\(pageId)" }
    /// Page titles the server didn't get, by page id (`UnsentTitle`).
    static let unsentTitles = "unsentTitles"
    /// Database fields the server didn't get, by `UnsentCell.key`.
    static let unsentCells = "unsentCells"
    static func breadcrumbs(_ pageId: String) -> String { "breadcrumbs/\(pageId)" }
    static func base(_ pageId: String) -> String { "base/\(pageId)" }
    static func baseView(_ pageId: String, viewId: String) -> String { "base/\(pageId)/view/\(viewId)" }
    static func tree(spaceId: String, parentPageId: String?) -> String { "tree/\(spaceId)/\(parentPageId ?? "root")" }
}

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

    private(set) var state: State = .restoring
    /// Saved sign-ins, one per server, including the current one.
    private(set) var accounts: [StoredSession] = []
    private let sessionStore: SessionStore
    /// Tests answer the API requests with a `URLProtocol`.
    private let protocolClasses: [AnyClass]?

    init(sessionStore: SessionStore = SessionStore(), protocolClasses: [AnyClass]? = nil) {
        self.sessionStore = sessionStore
        self.protocolClasses = protocolClasses
    }

    /// How long a start with saved content waits for the server: one that doesn't answer (behind a VPN that is off)
    /// would keep the launch screen up until the requests' timeout (30 s).
    @ObservationIgnored var startDeadline: Duration = .seconds(5)

    var hasAccounts: Bool { !accounts.isEmpty }

    /// Link previews of the signed-in session, made for its token; a new sign-in (or sign-out) starts afresh.
    @ObservationIgnored private var previewStore: (token: String, store: LinkPreviewStore)?

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
        return StoredAccounts.key(for: account.serverURL) == StoredAccounts.key(for: current)
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
        return StoredAccounts.key(for: ready.server.url) == StoredAccounts.key(for: session.server.url) && ready.token == session.token
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
                await restore()
                // Once per launch: a window opened later (iPad) would remove the cookie of an editor open in another.
                await WebEditorStores.removeLeftoverAuthCookies()
            }
        }
        await launchRestore?.value
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
                if await Self.hasNoNetwork() { throw APIError.network(URLError(.notConnectedToInternet)) }
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
                        server: server, client: client, imageLoader: ImageLoader(client: client, cache: cache), cache: cache,
                        token: stored.token, currentUser: cachedUser, entitlements: entitlements,
                        serverVersion: DebugLaunch.serverVersion ?? version, restoredOffline: true
                    ))
                    // The sign-in stopped waiting: it goes on in the background, as when the network returns.
                    if answeredLate { Task { await reconnectIfNeeded() } }
                    return
                }
                AppLog.session.error("Could not validate stored session: \(error.userMessage, privacy: .public)")
                state = .signedOut(server)
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
        guard let url = ServerURLNormalizer.normalize(input) else {
            throw AppSessionError.invalidServerURL
        }
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
        guard let host = url.host()?.lowercased() else { return nil }
        return accounts.first { account in
            account.serverURL.host()?.lowercased() == host && (account.serverURL.port ?? defaultPort(account.serverURL)) == (url.port ?? defaultPort(url))
        }
    }

    private func defaultPort(_ url: URL) -> Int {
        url.scheme?.lowercased() == "http" ? 80 : 443
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
        try await signIn(at: server) { .authenticated(token: try await LoginFlow.verifyMFA(client: $0, challenge: challenge, code: code)) }
    }

    /// Sign-in via the embedded browser (SSO/MFA), which captured the `authToken` cookie.
    func signIn(withToken token: String, at server: ServerInfo) async throws {
        // Before sign-in starts, so an invalid token never shows `.authenticating`.
        guard JWTClaims(token: token)?.isAccessToken == true else {
            throw APIError.unauthorized(message: String(localized: "The browser sign-in did not produce a valid session."))
        }
        try await signIn(at: server) { _ in .authenticated(token: token) }
    }

    /// Signs in to the sign-in screen's server. Once the app shows another (a link switched servers), it doesn't start,
    /// or ends without changing anything (`CancellationError`): the server switched to would get the other's token or
    /// MFA code, and the late answer would sign out of it or replace it.
    @discardableResult
    private func signIn(at screen: ServerInfo, _ login: (APIClient) async throws -> LoginResult) async throws -> SignInOutcome {
        // The state's copy: it can know more of the server (`loadWorkspaceInfo`).
        guard case .signedOut(let server) = state, Self.isSameServer(server, as: screen) else { throw CancellationError() }
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
                state = .signedOut(server)
                return .mfaRequired(challenge)
            }
        } catch {
            if isSigningIn(at: server) { state = .signedOut(server) }
            throw error
        }
    }

    private func isSigningIn(at server: ServerInfo) -> Bool {
        guard case .authenticating(let current) = state else { return false }
        return Self.isSameServer(current, as: server)
    }

    private static func isSameServer(_ server: ServerInfo, as other: ServerInfo) -> Bool {
        StoredAccounts.key(for: server.url) == StoredAccounts.key(for: other.url)
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

    @ObservationIgnored private var isSendingLogouts = false

    /// A sign-out for its server: `sendPendingLogouts` ends the session there, now or once the server answers; out of
    /// reach, it would stay valid there until it expires.
    private func keepPendingLogout(_ session: StoredSession) {
        keychain("keep the sign-out") {
            var pending = try sessionStore.pendingLogouts()
            pending.removeAll { StoredAccounts.key(for: $0.serverURL) == StoredAccounts.key(for: session.serverURL) && $0.token == session.token }
            pending.append(session)
            try sessionStore.setPendingLogouts(pending)
        }
    }

    /// Ends the sessions signed out while their server was out of reach (`signOut`): at launch, back in the app and when
    /// the network returns. A token that expired meanwhile, or that the server no longer knows (401), is dropped.
    func sendPendingLogouts() async {
        guard !isSendingLogouts, let pending = try? sessionStore.pendingLogouts(), !pending.isEmpty else { return }
        isSendingLogouts = true
        defer { isSendingLogouts = false }
        var done: [StoredSession] = []
        for entry in pending {
            if let expiresAt = entry.claims?.expiresAt, expiresAt < .now {
                done.append(entry)
                continue
            }
            do {
                _ = try await makeClient(for: entry.serverURL, token: entry.token).send(Endpoints.Auth.logout)
                done.append(entry)
            } catch let error as APIError where error.isSessionExpired {
                done.append(entry)
            } catch {
                AppLog.session.notice("Sign-out still waits for its server: \(error.userMessage, privacy: .public)")
            }
        }
        // Read again: a sign-out meanwhile added its own.
        keychain("update the waiting sign-outs") {
            try sessionStore.setPendingLogouts(try sessionStore.pendingLogouts().filter { !done.contains($0) })
        }
    }

    // MARK: - Unsent page titles

    @ObservationIgnored private var isSendingTitles = false
    @ObservationIgnored private var isSendingCells = false

    /// Keeps a page title the server didn't get; `sendUnsentTitles` sends it once the server answers. False if it couldn't
    /// be kept (the kept titles can't be read, or not written): then nothing may promise it a later try.
    /// `store`: the unsent changes of the session the page was opened in, as the editor engine keeps its own; a 401 or a
    /// switch may have ended that session meanwhile. Without one, the current session's.
    @discardableResult
    func keepUnsentTitle(_ title: String, pageId: String, spaceId: String?, in store: DiskCache? = nil) async -> Bool {
        guard let store = store ?? ready?.unsentChanges else { return false }
        do {
            // In one step: a title kept or sent meanwhile (another window) isn't lost.
            try await store.update([String: UnsentTitle].self, key: CacheKey.unsentTitles, initial: [:]) {
                $0[pageId] = UnsentTitle(title: title, spaceId: spaceId)
            }
            return true
        } catch {
            AppLog.session.error("Title not kept: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The page's kept title, if it still waits for the server.
    func unsentTitle(pageId: String) async -> String? {
        await ready?.unsentChanges.read([String: UnsentTitle].self, key: CacheKey.unsentTitles)?[pageId]?.title
    }

    /// Drops the page's kept title: it, or a newer one, reached the server. With `title`, only while it is still that one:
    /// a newer title kept meanwhile stays.
    func forgetUnsentTitle(pageId: String, title: String? = nil) async {
        guard let store = ready?.unsentChanges else { return }
        do {
            try await store.update([String: UnsentTitle].self, key: CacheKey.unsentTitles, initial: [:]) { titles in
                if let kept = titles[pageId], title == nil || kept.title == title { titles[pageId] = nil }
            }
        } catch {
            AppLog.session.error("Kept title not dropped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A kept title or field that can never go (`UnsentChanges.isFinal`), dropped by `sendUnsentTitles` or
    /// `sendUnsentCells`: `name` is what the user typed.
    struct DroppedChange: Sendable {
        let name: String
        let reason: String

        /// The notice for changes dropped: the page or entry was deleted, access to it removed or the input refused, and
        /// the user expects them saved.
        static func notice(for dropped: [DroppedChange]) -> String? {
            guard let first = dropped.first else { return nil }
            return dropped.count == 1
                ? String(localized: "“\(first.name)” not saved: \(first.reason)")
                : String(localized: "\(dropped.count) changes not saved, among them “\(first.name)”: \(first.reason)")
        }
    }

    /// Sends the kept titles. Returns the spaces whose pages got theirs, and the titles that can never go, which it
    /// dropped; after another error the rest waits for the next try (going online, back in the app, opening a page).
    func sendUnsentTitles() async -> (spaces: [String], dropped: [DroppedChange]) {
        guard !isSendingTitles, let session = ready else { return ([], []) }
        isSendingTitles = true
        defer { isSendingTitles = false }
        let store = session.unsentChanges
        let titles: [String: UnsentTitle]
        do {
            titles = try await store.readThrowing([String: UnsentTitle].self, key: CacheKey.unsentTitles) ?? [:]
        } catch {
            AppLog.session.error("Kept titles unreadable: \(error.localizedDescription, privacy: .public)")
            return ([], [])
        }
        var spaces: [String] = [], dropped: [DroppedChange] = []
        for (pageId, kept) in titles {
            // A newer title saved meanwhile replaced or dropped this one.
            guard (try? await store.readThrowing([String: UnsentTitle].self, key: CacheKey.unsentTitles))?[pageId]?.title == kept.title
            else { continue }
            do {
                // Another account's pages don't exist on its server: after a switch nothing more goes out.
                _ = try await send(Endpoints.Pages.update(pageId: pageId, title: kept.title), on: session)
                if let spaceId = kept.spaceId { spaces.append(spaceId) }
            } catch let error where UnsentChanges.isFinal(error) {
                AppLog.session.error("Kept title dropped: \(error.userMessage, privacy: .public)")
                dropped.append(DroppedChange(name: kept.title, reason: error.userMessage))
            } catch {
                break
            }
            // A title kept for the page meanwhile stays.
            try? await store.update([String: UnsentTitle].self, key: CacheKey.unsentTitles, initial: [:]) { titles in
                if titles[pageId]?.title == kept.title { titles[pageId] = nil }
            }
        }
        return (spaces, dropped)
    }

    /// Sends the kept database fields (`UnsentCell`), as `sendUnsentTitles` does titles. Returns the ones that can never
    /// go (entry deleted, access gone, value refused), which it dropped.
    func sendUnsentCells() async -> [DroppedChange] {
        guard !isSendingCells, let session = ready else { return [] }
        isSendingCells = true
        defer { isSendingCells = false }
        let store = session.unsentChanges
        let cells: [String: UnsentCell]
        do {
            cells = try await store.readThrowing([String: UnsentCell].self, key: CacheKey.unsentCells) ?? [:]
        } catch {
            AppLog.session.error("Kept fields unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var dropped: [DroppedChange] = []
        for (key, kept) in cells {
            // A newer input saved or kept meanwhile replaced or dropped this one.
            guard (try? await store.readThrowing([String: UnsentCell].self, key: CacheKey.unsentCells))?[key] == kept else { continue }
            do {
                let endpoint = Endpoints.Bases.updateRow(pageId: kept.basePageId, rowId: kept.rowId, cells: [kept.propertyId: kept.value])
                _ = try await send(endpoint, on: session)
            } catch let error where UnsentChanges.isFinal(error) {
                AppLog.session.error("Kept field dropped: \(error.userMessage, privacy: .public)")
                dropped.append(DroppedChange(name: kept.typed.isEmpty ? kept.propertyName : kept.typed, reason: error.userMessage))
            } catch {
                break
            }
            try? await store.update([String: UnsentCell].self, key: CacheKey.unsentCells, initial: [:]) { cells in
                if cells[key] == kept { cells[key] = nil }
            }
        }
        return dropped
    }

    /// Runs an API call and ends its session on 401. All data loaders use it.
    func perform<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
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

    /// Handles a 401. Idempotent: concurrent 401s trigger only one transition.
    func handleUnauthorized() {
        guard case .ready(let session) = state else { return }
        AppLog.session.notice("Session rejected (401), returning to sign-in")
        keychain("remove") { try sessionStore.remove(serverURL: session.server.url) }
        reloadAccounts()
        state = .signedOut(session.server)
    }

    /// Revalidates the session when the app returns to the foreground.
    func refreshCurrentUser() async {
        guard case .ready(let session) = state else { return }
        if session.restoredOffline {
            await reconnectIfNeeded()
            return
        }
        do {
            let user = try await session.client.send(Endpoints.Users.me)
            // The current state, not `session`: switching servers and back meanwhile replaced the client and cache.
            guard isStillCurrent(session), case .ready(var current) = state else { return }
            // Usually unchanged: writing `state` anyway would rebuild every view that reads the session.
            if user != current.currentUser {
                current.currentUser = user
                state = .ready(current)
            }
            // Also when unchanged: an offline start needs it, and iOS may have purged the cache meanwhile.
            await current.cache.write(user, key: CacheKey.currentUser)
        } catch let error as APIError where error.isSessionExpired {
            if isStillCurrent(session) { handleUnauthorized() }
        } catch {
            AppLog.session.debug("Refresh skipped: \(error.userMessage, privacy: .public)")
        }
    }

    /// Clears the current server's offline cache, except the user, license and version that an offline start restores.
    func clearCache() async {
        guard let ready else { return }
        let version = await ready.cache.read(String.self, key: CacheKey.serverVersion)
        await ready.cache.removeAll()
        await ready.cache.write(ready.currentUser, key: CacheKey.currentUser)
        await ready.cache.write(ready.entitlements, key: CacheKey.entitlements)
        if let version { await ready.cache.write(version, key: CacheKey.serverVersion) }
        // Not its staged uploads: a running upload reads them.
        await removeLocalData(for: ready.server.url, uploads: false)
    }

    // MARK: - Internal

    /// `replacing`: the offline session that a reconnect loads fully. `signingIn`: a sign-in from the sign-in screen.
    private func finishSignIn(
        server: ServerInfo, client: APIClient, token: String, replacing: ReadySession? = nil, signingIn: Bool = false
    ) async throws {
        async let me = client.send(Endpoints.Users.me)
        async let entitlements = client.send(Endpoints.Workspace.entitlements)
        async let version = client.send(Endpoints.Version.info)
        let currentUser = try await me

        var server = server
        if server.workspace == nil {
            server.workspace = try? await client.send(Endpoints.Workspace.publicInfo)
        }
        let cache = makeCache(for: server.url)
        if await Self.storeCurrentUser(currentUser, in: cache) {
            await removeLocalData(for: server.url)
        }
        // Every edition answers this, so a failure is a hiccup: keep the last known license (from this user's cache,
        // hence after `storeCurrentUser`).
        let resolvedEntitlements: Entitlements
        do {
            resolvedEntitlements = try await entitlements
            await cache.write(resolvedEntitlements, key: CacheKey.entitlements)
        } catch {
            AppLog.session.error("Entitlements unavailable, using cached: \(error.userMessage, privacy: .public)")
            let cached = await cache.read(Entitlements.self, key: CacheKey.entitlements)
            resolvedEntitlements = cached ?? .community
            // Written again: `prune` below goes by age and size, like for photos and PDFs in the same cache.
            if let cached { await cache.write(cached, key: CacheKey.entitlements) }
        }
        // Docmost names its version only after asking GitHub for its latest release, and nothing when GitHub refuses
        // (60 requests an hour from one address) or a proxy blocks it: keep the last one it named.
        let serverVersion: String?
        if let current = (try? await version)?.currentVersion {
            serverVersion = current
            await cache.write(current, key: CacheKey.serverVersion)
        } else {
            serverVersion = await cache.read(String.self, key: CacheKey.serverVersion)
            // Written again, as the license above: a version the server stopped naming would only age.
            if let serverVersion { await cache.write(serverVersion, key: CacheKey.serverVersion) }
        }
        // A reconnect must not undo a switch or sign-out made meanwhile, nor a sign-in a switch; no await from here to the
        // `state` write.
        if let replacing, !isStillCurrent(replacing) { return }
        if signingIn, !isSigningIn(at: server) { throw CancellationError() }
        let stored = StoredSession(serverURL: server.url, token: token, email: currentUser.user.email, workspaceName: currentUser.workspace.name)
        keychain("save") { try sessionStore.save(stored) }
        reloadAccounts()
        Task.detached(priority: .utility) { await cache.prune() }
        state = .ready(ReadySession(
            server: server, client: client, imageLoader: ImageLoader(client: client, cache: cache), cache: cache,
            token: token, currentUser: currentUser, entitlements: resolvedEntitlements,
            serverVersion: DebugLaunch.serverVersion ?? serverVersion
        ))
        AppLog.session.info("Signed in as \(currentUser.user.email, privacy: .private) at \(server.url.absoluteString, privacy: .public)")
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
        // A fresh configuration per client: clients made from one share its in-memory URL cache.
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return APIClient(baseURL: url, token: token, userAgent: Self.userAgent, configuration: configuration, logger: AppLog.apiRequestLogger)
    }

    private func makeCache(for url: URL) -> DiskCache {
        DiskCache(scope: url.absoluteString)
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

    /// Removes what the offline cache doesn't cover: downloads, the system URL cache (files of older builds, logos and
    /// avatars) and the server's web editor data.
    private func removeLocalData(for serverURL: URL, uploads: Bool = true) async {
        TempFile.removeAll(server: serverURL, uploads: uploads)
        // Holds only member avatars, of every server: it can't be cleared for one.
        URLCache.shared.removeAllCachedResponses()
        await WebEditorStores.remove(for: serverURL)
    }

    /// The current network path; a monitor reports it right after starting.
    private static func hasNoNetwork() async -> Bool {
        for await path in NWPathMonitor() { return path.status != .satisfied }
        return false
    }

    /// After an offline start, fully loads the session once the server is reachable again.
    func reconnectIfNeeded() async {
        guard case .ready(let session) = state, session.restoredOffline else { return }
        do {
            try await finishSignIn(server: session.server, client: session.client, token: session.token, replacing: session)
        } catch let error as APIError where error.isSessionExpired {
            if isStillCurrent(session) { handleUnauthorized() }
        } catch {
            AppLog.session.debug("Still offline: \(error.userMessage, privacy: .public)")
        }
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
            let current = keychain("load", { try sessionStore.load() }).map { StoredAccounts.key(for: $0.serverURL) }
            if current != StoredAccounts.key(for: account.serverURL) {
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
