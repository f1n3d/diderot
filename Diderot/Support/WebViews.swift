import WebKit

/// The app's web views, set up by role in one place: the website data they keep, whether their pages run scripts, the
/// frames they load and where they may go (`WebNavigationLimit`). The pages bring their own content rules: the
/// islands' (`IslandHTML`), the server's.
enum WebViews {
    /// The islands' website data: nothing is kept, and one store serves them all.
    static let islandStore = WKWebsiteDataStore.nonPersistent()

    /// A formula, diagram or SVG from the app's bundle (`WebIslandView`): its own page only, no frames.
    static func island() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = islandStore
        return WebPage(configuration: configuration, navigationDecider: WebNavigationLimit(home: IslandHTML.baseURL))
    }

    /// The diagram viewer (`ZoomableDiagram`): an island without scripts in a `WKWebView`. It doesn't keep `limit`, its
    /// navigation delegate: the caller does.
    static func diagramViewer() -> (view: WKWebView, limit: WebNavigationLimit) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = islandStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        let limit = WebNavigationLimit(home: IslandHTML.baseURL)
        view.navigationDelegate = limit
        return (view, limit)
    }

    /// The page's web layout (`WebLayoutView`): the server's HTML of the page, with embeds in frames; a tapped link goes
    /// outside. Its store keeps nothing and gets the auth cookie for images and attachments.
    static func webLayout(server: URL) -> (page: WebPage, dataStore: WKWebsiteDataStore, limit: WebNavigationLimit) {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        let limit = WebNavigationLimit(home: server, frames: true)
        return (WebPage(configuration: configuration, navigationDecider: limit), dataStore, limit)
    }

    /// The web editor (`WebEditorView`): the server's pages, frames (embeds, the draw.io editor), `window.open` outside.
    /// A persistent store of the server's own (`WebEditorStores`): the editor needs IndexedDB (Yjs offline cache),
    /// which a non-persistent store lacks; the auth cookie is removed on close.
    static func webEditor(server: URL, store: UUID) -> (page: WebPage, dataStore: WKWebsiteDataStore, limit: WebNavigationLimit) {
        let dataStore = WKWebsiteDataStore(forIdentifier: store)
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        let limit = WebNavigationLimit(home: server, reach: .origin, frames: true)
        limit.catchesWindowOpen(in: &configuration)
        return (WebPage(configuration: configuration, navigationDecider: limit), dataStore, limit)
    }

    /// The editor engine's page (`WebDocumentEngine`): its own page only, no frames either (TipTap renders YouTube
    /// embeds as iframes), so nothing else hears of it; nothing kept. `configure` adds its message handlers.
    static func engine(server: URL, configure: (inout WebPage.Configuration) -> Void) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configure(&configuration)
        return WebPage(configuration: configuration, navigationDecider: WebNavigationLimit(home: server))
    }

    /// Signing in in the browser (`BrowserLoginView`): no limit, as a single sign-on passes other services' pages,
    /// which decide how they open the next. Nothing kept; the sign-in takes the auth cookie from the store.
    static func browserSignIn() -> (page: WebPage, dataStore: WKWebsiteDataStore) {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        return (WebPage(configuration: configuration), dataStore)
    }

    /// Connecting an integration (`IntegrationConnectSheet`): signed in on the server, and the services' sign-in pages
    /// over http(s), with their frames; a tapped link to a new window or another app goes outside. Nothing kept.
    static func integrationConnect(server: URL) -> (page: WebPage, dataStore: WKWebsiteDataStore, limit: WebNavigationLimit) {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        let limit = WebNavigationLimit(home: server, reach: .web, frames: true)
        return (WebPage(configuration: configuration, navigationDecider: limit), dataStore, limit)
    }
}
