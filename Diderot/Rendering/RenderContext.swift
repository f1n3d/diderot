import SwiftUI
import DocmostKit

/// What block views need to render: server URL for relative links and media, API client for files behind sign-in,
/// image loader, token for media cookies, current page.
struct RenderContext: Sendable {
    let baseURL: URL?
    let client: APIClient?
    let imageLoader: ImageLoader?
    let token: String?
    let pageId: String?

    static let empty = RenderContext(baseURL: nil, client: nil, imageLoader: nil, token: nil, pageId: nil)

    /// `authToken` cookie for AVFoundation (the server checks the cookie before the bearer header).
    func authCookie() -> HTTPCookie? {
        HTTPCookie.docmostAuth(token: token, serverURL: baseURL)
    }

    /// Content media `src` resolved against the server URL (nil without a server).
    func mediaURL(_ src: String?) -> URL? {
        baseURL.flatMap { ImageURL.resolveContentMedia(src, baseURL: $0) }
    }

    /// Whether media at `url` loads by itself: from the server, or from anywhere with Settings › "Load Content from Other
    /// Servers" on. From another host it loads only after a tap otherwise (`OtherServerCard`): it would tell that host who
    /// reads the page and when, as a tracking pixel does, while nothing is to leave the device but to the own server.
    func loadsByItself(_ url: URL) -> Bool {
        Self.loadsByItself(url, server: baseURL)
    }

    nonisolated static let loadsOtherServersKey = "loadsContentFromOtherServers"

    nonisolated static func loadsByItself(_ url: URL, server: URL?) -> Bool {
        // A file on the device tells nobody anything.
        if url.isFileURL { return true }
        guard let server else { return false }
        return WebNavigationLimit.sameOrigin(url, server) || UserDefaults.standard.bool(forKey: loadsOtherServersKey)
    }
}

/// Media from another server in place of the media, until tapped (`RenderContext.loadsByItself`).
struct OtherServerCard: View {
    let icon: String
    let title: String
    let url: URL
    let load: () -> Void

    var body: some View {
        Button(action: load) {
            PlaceholderCard(icon: icon, title: title, detail: String(localized: "From \(url.host() ?? url.absoluteString). Tap to load."))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Loads it from that server"))
    }
}

extension RenderContext {
    init(session: AppSession, pageId: String?) {
        self.init(baseURL: session.server?.url, client: session.client, imageLoader: session.ready?.imageLoader,
                  token: session.ready?.token, pageId: pageId)
    }
}

extension HTTPCookie {
    /// `authToken` cookie for WebViews and AVFoundation; HttpOnly and SameSite=Lax like the server's, so page scripts
    /// can't read the token.
    static func docmostAuth(token: String?, serverURL: URL?) -> HTTPCookie? {
        guard let token, let host = serverURL?.host() else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "authToken", .value: token, .domain: host, .path: "/",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax,
        ]
        if serverURL?.scheme == "https" {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }
}

extension EnvironmentValues {
    @Entry var renderContext: RenderContext = .empty
    @Entry var listDepth: Int = 0
    /// The synced blocks shown around a view ("sourcePageId/transclusionId", outermost first): one that contains itself
    /// would load and nest forever.
    @Entry var syncedBlockChain: [String] = []
}

/// Navigation stack of a tab (`MainTabView`); the reader pushes internal links, mentions and subpages onto it.
@MainActor
@Observable
final class ReaderNavigation {
    var path = NavigationPath()
    /// Opens pages elsewhere instead of pushing them: the page history, a sheet, hands them to its page.
    @ObservationIgnored var redirect: ((PageSelection) -> Void)?

    func open(_ selection: PageSelection) {
        if let redirect { redirect(selection) } else { path.append(selection) }
    }
}
