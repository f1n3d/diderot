import SwiftUI
import WebKit

/// Fallback "Web Layout": `pages/info format: html` in a WebView. API images and attachments load via the `authToken`
/// cookie in a non-persistent data store. Links open as on the page, embeds play as on the web.
struct WebLayoutView: View {
    let html: String
    let title: String
    let serverURL: URL
    let token: String?
    @State private var dataStore: WKWebsiteDataStore
    @State private var limit: WebNavigationLimit
    @State private var page: WebPage
    @State private var isReady = false
    @Environment(\.openURL) private var openURL

    init(html: String, title: String, serverURL: URL, token: String?) {
        self.html = html
        self.title = title
        self.serverURL = serverURL
        self.token = token
        let dataStore = WKWebsiteDataStore.nonPersistent()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        let limit = WebNavigationLimit(home: serverURL, frames: true)
        self._dataStore = State(initialValue: dataStore)
        self._limit = State(initialValue: limit)
        self._page = State(initialValue: WebPage(configuration: configuration, navigationDecider: limit))
    }

    var body: some View {
        WebView(page)
            .opacity(isReady ? 1 : 0)
            .overlay {
                if !isReady { ProgressView() }
            }
            .task(id: html) {
                limit.openOutside = { [openURL] in openURL($0) }
                await installCookie()
                page.load(html: Self.wrap(html, title: title), baseURL: serverURL)
                isReady = true
            }
    }

    private func installCookie() async {
        guard let cookie = HTTPCookie.docmostAuth(token: token, serverURL: serverURL) else { return }
        await dataStore.httpCookieStore.setCookie(cookie)
    }

    /// Minimal stylesheet so the exported HTML is readable and follows the system appearance.
    private static func wrap(_ body: String, title: String) -> String {
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // script-src 'none': page scripts can't run signed in on the server's origin; cross-origin embeds keep theirs.
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'">
        <meta name="color-scheme" content="light dark">
        <style>
          :root { color-scheme: light dark; }
          body { font: -apple-system-body; font-family: -apple-system, system-ui; line-height: 1.5;
                 margin: 16px; max-width: 760px; word-wrap: break-word; }
          img, video, iframe { max-width: 100%; height: auto; }
          pre { overflow-x: auto; padding: 12px; background: rgba(127,127,127,0.12); border-radius: 8px; }
          code { font-family: ui-monospace, Menlo, monospace; font-size: 0.92em; }
          blockquote { border-left: 3px solid rgba(10,132,255,0.6); margin: 0; padding-left: 12px; }
          table { border-collapse: collapse; } td, th { border: 1px solid rgba(127,127,127,0.4); padding: 6px 8px; }
          [data-type="callout"] { padding: 12px; border-radius: 10px; background: rgba(10,132,255,0.12); }
          a { color: #0a84ff; }
        </style>
        </head>
        <body><h1>\(escapedTitle)</h1>\(body)</body>
        </html>
        """
    }
}
