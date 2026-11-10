import SwiftUI
import WebKit
import DocmostKit

/// The real Docmost editor in a WebView: loads `/p/<slugId>` with the `authToken` cookie so live collaboration,
/// history and permissions come from the web client. CSS trims the app shell (sidebars). It stays on the server: links
/// elsewhere open as from a page, never in the editor without an address bar.
struct WebEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let page: Page
    let serverURL: URL
    let token: String
    var onClose: () -> Void = {}

    private let storeID: UUID
    /// Made once: built in `init`, a page and its store came anew on every pass of the page view while the editor showed.
    @State private var parts = Once<Parts>()
    @State private var phase = Phase.loading
    /// Counts "Try Again": each one loads the editor anew.
    @State private var attempt = 0

    /// What the sheet shows: the spinner, the editor, or why it didn't load.
    private enum Phase {
        case loading
        case ready
        case failed(any Error)
    }

    private struct Parts {
        let dataStore: WKWebsiteDataStore
        let limit: WebNavigationLimit
        let webPage: WebPage
    }

    init(page: Page, serverURL: URL, token: String, onClose: @escaping () -> Void = {}) {
        self.page = page
        self.serverURL = serverURL
        self.token = token
        self.onClose = onClose
        storeID = WebEditorStores.identifier(for: serverURL)
    }

    private var editor: Parts {
        parts {
            let editor = WebViews.webEditor(server: serverURL, store: storeID)
            return Parts(dataStore: editor.dataStore, limit: editor.limit, webPage: editor.page)
        }
    }

    private var dataStore: WKWebsiteDataStore { editor.dataStore }
    private var limit: WebNavigationLimit { editor.limit }
    private var webPage: WebPage { editor.webPage }

    var body: some View {
        NavigationStack {
            WebView(webPage)
                .opacity(isReady ? 1 : 0)
                .overlay {
                    switch phase {
                    case .loading: ProgressView("Loading editor…")
                    case .ready: EmptyView()
                    case .failed(let error): ErrorStateView(error: error) { attempt += 1 }
                    }
                }
                .navigationTitle(page.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                .task(id: attempt) {
                    limit.openOutside = { [openURL] in openURL($0) }
                    phase = .loading
                    do {
                        try await load()
                        phase = .ready
                    } catch {
                        // A closed editor's load fails as it likes: its sheet is gone.
                        if !Task.isCancelled { phase = .failed(error) }
                    }
                }
        }
        .onAppear { WebEditorStores.editorOpened(storeID) }
        // iPad windows share a server's store: its cookie goes with the last editor, not while another one still saves.
        .onDisappear {
            if WebEditorStores.editorClosed(storeID) { Task { await removeCookies() } }
            onClose()
        }
    }

    private func removeCookies() async {
        for cookie in await dataStore.httpCookieStore.allCookies() where cookie.name == "authToken" {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }

    private var isReady: Bool {
        if case .ready = phase { true } else { false }
    }

    private func load() async throws {
        if let cookie = HTTPCookie.docmostAuth(token: token, serverURL: serverURL) {
            await dataStore.httpCookieStore.setCookie(cookie)
        }
        try await Self.open(ContentLinkRouter.webPageURL(server: serverURL, slugId: page.slugId ?? page.id), home: serverURL, in: webPage)
    }

    /// A load the editor's limit stopped (`WebNavigationLimit`): the server sent it to another address, such as a
    /// sign-in in front of it, where the editor doesn't go.
    struct RedirectedAway: LocalizedError, Equatable {
        /// Scheme, host and port: the same host on another port or scheme is another address too.
        let address: String

        var errorDescription: String? {
            String(localized: "The server redirects to \(address). The web editor opens only the server's own pages; use “Open in Browser” instead.")
        }
    }

    /// Why a load failed, in words for the sheet. WebKit calls a load that a navigation decider stopped after a
    /// redirect "Frame load interrupted" (`WebKitErrorFrameLoadInterruptedByPolicyChange`, with the address it was
    /// sent to; seen on iOS 27.0 on November 10, 2026).
    nonisolated static func reason(_ error: any Error) -> any Error {
        let failure = error as NSError
        if failure.domain == "WebKitErrorDomain", failure.code == 102,
           let url = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL, let scheme = url.scheme, let host = url.host() {
            return RedirectedAway(address: "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? ""))
        }
        return error
    }

    /// Loads the server's home page and then the page into the editor's web page. Throws why a load failed (offline,
    /// the server unreachable or redirecting elsewhere): the sheet says so, as WebKit draws nothing for a load that
    /// never began.
    static func open(_ pageURL: URL, home: URL, in webPage: WebPage) async throws {
        // The web client's page view crashes while its user cache `localStorage.currentUser` is empty (first load);
        // the home page fills it, once it has asked the server who's signed in.
        webPage.load(URLRequest(url: home))
        try await loaded(webPage)
        _ = try? await webPage.callJavaScript(userCachedScript)
        // Closing the editor cancels this task, also mid-wait; don't open the page then.
        try Task.checkCancellation()
        webPage.load(URLRequest(url: pageURL))
        try await loaded(webPage)
        // Hide the shell once the app has rendered it (best effort; the classes come from Mantine AppShell).
        _ = try? await webPage.callJavaScript(trimShellScript)
    }

    /// Waits for the page's load to end and throws why it failed. Page-wide events, not the load's: those stop the
    /// load when this task is cancelled, and then callJavaScript never returns (`WebIslandView`).
    private static func loaded(_ webPage: WebPage) async throws {
        while true {
            do {
                for try await event in webPage.navigations {
                    if case .finished = event { return }
                }
                throw WebPage.NavigationError.pageClosed
            } catch WebPage.NavigationError.failedProvisionalNavigation(let error) {
                // Replaced by the next load (a redirect): that one's end counts.
                if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { continue }
                // The reason itself, which has the words ("The Internet connection appears to be offline.").
                throw reason(error)
            }
        }
    }

    /// Answers once the web client has cached the signed-in user (`true`), or after 15 s (`false`). The client writes
    /// the cache with `localStorage.setItem`, which reports it while this waits; no event says so otherwise.
    private static let userCachedScript = """
    if (localStorage.getItem("currentUser") !== null) { return true; }
    return await new Promise((resolve) => {
        const storage = Storage.prototype;
        const setItem = storage.setItem;
        const finish = (cached) => {
            storage.setItem = setItem;
            clearTimeout(timer);
            resolve(cached);
        };
        const timer = setTimeout(() => finish(false), 15000);
        storage.setItem = function (key, value) {
            setItem.call(this, key, value);
            if (this === localStorage && key === "currentUser") { finish(true); }
        };
    });
    """

    /// Hides the shell's sidebars once the client has rendered the shell (`true`), or answers `false` after 10 s.
    private static let trimShellScript = """
    const trim = () => {
        if (!document.querySelector(".mantine-AppShell-main")) { return false; }
        if (!document.getElementById("docmost-ios-style")) {
            const style = document.createElement("style");
            style.id = "docmost-ios-style";
            style.textContent = `
                .mantine-AppShell-navbar, .mantine-AppShell-aside { display: none !important; }
                .mantine-AppShell-main { padding-left: 0 !important; padding-right: 0 !important; }
            `;
            document.head.appendChild(style);
        }
        return true;
    };
    if (trim()) { return true; }
    return await new Promise((resolve) => {
        const finish = (trimmed) => {
            observer.disconnect();
            clearTimeout(timer);
            resolve(trimmed);
        };
        const observer = new MutationObserver(() => { if (trim()) { finish(true); } });
        const timer = setTimeout(() => finish(false), 10000);
        observer.observe(document.documentElement, { childList: true, subtree: true });
    });
    """
}

/// The web editor's website data (the auth cookie, the web client's storage and its Yjs offline cache in IndexedDB) in
/// one WebKit data store per server, so signing out removes exactly that server's, all of it. Before, the servers shared
/// one store, from which a server's data couldn't always be told apart.
enum WebEditorStores {
    /// The store all servers shared until October 2026. The first server to open the web editor afterwards takes it
    /// over, with edits it may hold that didn't reach the server yet (the web client syncs them when it opens the page).
    private static let shared = UUID(uuidString: "6E2F3C1A-5B7D-4E8F-9A0B-1C2D3E4F5A6B")!
    private static let key = "webEditorStores"

    /// Editors open per store (iPad windows share a server's).
    private static var openEditors: [UUID: Int] = [:]
    static func editorOpened(_ store: UUID) { openEditors[store, default: 0] += 1 }
    /// Whether that was the store's last open editor.
    static func editorClosed(_ store: UUID) -> Bool {
        let remaining = (openEditors[store] ?? 1) - 1
        openEditors[store] = remaining > 0 ? remaining : nil
        return remaining <= 0
    }

    /// The server's store, the same across launches.
    static func identifier(for server: URL, defaults: UserDefaults = .standard) -> UUID {
        var stores = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let serverKey = StoredAccounts.key(for: server)
        if let identifier = stores[serverKey].flatMap(UUID.init(uuidString:)) { return identifier }
        let identifier = stores.values.contains(shared.uuidString) ? UUID() : shared
        stores[serverKey] = identifier.uuidString
        defaults.set(stores, forKey: key)
        return identifier
    }

    /// Removes the server's store and everything in it (sign-out, another user signed in there).
    static func remove(for server: URL, defaults: UserDefaults = .standard) async {
        var stores = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard let identifier = stores.removeValue(forKey: StoredAccounts.key(for: server)).flatMap(UUID.init(uuidString:)) else { return }
        defaults.set(stores, forKey: key)
        // Removing a store doesn't set WebKit up, getting the default one does. Without that, removing before any web
        // view existed in this launch (another user signing in right at launch) crashed inside WebKit.
        _ = WKWebsiteDataStore.default()
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
        } catch {
            // In use (an editor still open): empty it instead; the store itself goes with the next sign-out there.
            let store = WKWebsiteDataStore(forIdentifier: identifier)
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    /// Removes the server's web editor cache, not its own storage: the web client keeps the edits the server doesn't
    /// have yet there ("Clear Saved Content").
    static func removeCache(for server: URL, defaults: UserDefaults = .standard) async {
        let stores = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard let identifier = stores[StoredAccounts.key(for: server)].flatMap(UUID.init(uuidString:)) else { return }
        // As in `remove`: WebKit set up first.
        _ = WKWebsiteDataStore.default()
        let caches: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        await WKWebsiteDataStore(forIdentifier: identifier).removeData(ofTypes: caches, modifiedSince: .distantPast)
    }

    /// Auth cookies an editor left when the app ended while it was open (they're removed on close otherwise).
    static func removeLeftoverAuthCookies(defaults: UserDefaults = .standard) async {
        let stores = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        for identifier in stores.values.compactMap(UUID.init(uuidString:)) {
            let cookies = WKWebsiteDataStore(forIdentifier: identifier).httpCookieStore
            for cookie in await cookies.allCookies() where cookie.name == "authToken" {
                await cookies.deleteCookie(cookie)
            }
        }
    }
}
