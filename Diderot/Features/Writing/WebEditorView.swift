import SwiftUI
import WebKit
import DocmostKit

/// The real Docmost editor in a WebView: loads `/p/<slugId>` with the `authToken` cookie so live collaboration,
/// history and permissions come from the web client. CSS trims the app shell (sidebars).
struct WebEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let page: Page
    let serverURL: URL
    let token: String
    var onClose: () -> Void = {}

    @State private var dataStore: WKWebsiteDataStore
    @State private var webPage: WebPage
    @State private var isReady = false

    init(page: Page, serverURL: URL, token: String, onClose: @escaping () -> Void = {}) {
        self.page = page
        self.serverURL = serverURL
        self.token = token
        self.onClose = onClose
        // Dedicated persistent store: the web editor needs IndexedDB (Yjs offline cache), which a non-persistent
        // store lacks. The auth cookie is removed on close.
        let dataStore = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier)
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        self._dataStore = State(initialValue: dataStore)
        self._webPage = State(initialValue: WebPage(configuration: configuration))
    }

    /// Fixed identifier so the editor keeps its cache across sessions.
    static let storeIdentifier = UUID(uuidString: "6E2F3C1A-5B7D-4E8F-9A0B-1C2D3E4F5A6B")!

    /// Removes the editor's website data except that of `keptHosts`. WebKit names records by domain ("example.com" for
    /// "wiki.example.com") and lists none for hosts without a public suffix (`docmost.local`), so only removing
    /// everything reaches those.
    static func removeData(keepingHosts keptHosts: [String]) async {
        let store = WKWebsiteDataStore(forIdentifier: storeIdentifier)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        guard !keptHosts.isEmpty else {
            await store.removeData(ofTypes: types, modifiedSince: .distantPast)
            return
        }
        // shortcut: a removed host keeps its data if it has no public suffix or shares its domain with a saved server,
        // give each server its own store if that matters.
        let records = await store.dataRecords(ofTypes: types).filter { record in
            !keptHosts.contains { $0 == record.displayName || $0.hasSuffix("." + record.displayName) }
        }
        await store.removeData(ofTypes: types, for: records)
    }

    var body: some View {
        NavigationStack {
            WebView(webPage)
                .opacity(isReady ? 1 : 0)
                .overlay { if !isReady { ProgressView("Loading editor…") } }
                .navigationTitle(page.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                .task { try? await load() }
        }
        .onDisappear {
            Task { await removeCookies() }
            onClose()
        }
    }

    private func removeCookies() async {
        for cookie in await dataStore.httpCookieStore.allCookies() where cookie.name == "authToken" {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }

    private func load() async throws {
        if let cookie = HTTPCookie.docmostAuth(token: token, serverURL: serverURL) {
            await dataStore.httpCookieStore.setCookie(cookie)
        }
        // The web client's page view crashes while its user cache `localStorage.currentUser` is empty (first load);
        // the home page fills it.
        webPage.load(URLRequest(url: serverURL))
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(500))
            if !webPage.isLoading, (try? await webPage.callJavaScript("return localStorage.getItem('currentUser') !== null;")) as? Bool == true {
                break
            }
        }
        // Closing the editor cancels this task, also mid-check; don't open the page then.
        try Task.checkCancellation()
        webPage.load(URLRequest(url: ContentLinkRouter.webPageURL(server: serverURL, slugId: page.slugId ?? page.id)))
        // Hide the shell once the app has rendered (best effort; the classes come from Mantine AppShell).
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            if !webPage.isLoading, (try? await webPage.callJavaScript(Self.trimShellScript)) as? Bool == true {
                break
            }
        }
        isReady = true
    }

    private static let trimShellScript = """
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
    """
}
