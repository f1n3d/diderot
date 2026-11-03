import WebKit
import DocmostKit

/// Keeps a web view on the pages the app loads into it, so neither a link nor a script takes it elsewhere: where
/// `reach` says, from `home` (the base URL its HTML loads with). A link tapped there, or a window it opens, goes to
/// `openOutside` instead (the view's `openURL`, as from a page); other navigations away don't happen. Frames (embeds)
/// load only if `frames`. The decider of a `WebPage`, and the navigation delegate of a `WKWebView`, which doesn't keep it.
final class WebNavigationLimit: NSObject, WebPage.NavigationDeciding, WKNavigationDelegate {
    enum Decision: Equatable {
        case allow
        case cancel
        case openOutside
    }

    /// Where the main frame may go.
    enum Reach {
        /// The page at `home`, at any anchor.
        case page
        /// Every page of home's origin (the web editor on its server).
        case origin
        /// Any web page (`http`, `https`): a sign-in that passes other services' pages.
        case web
    }

    private let home: URL
    let reach: Reach
    let frames: Bool
    /// Set once the view is shown; until then tapped links are dropped.
    var openOutside: ((URL) -> Void)?

    init(home: URL, reach: Reach = .page, frames: Bool = false) {
        self.home = home
        self.reach = reach
        self.frames = frames
    }

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        decide(action.request.url, mainFrame: action.target?.isMainFrame, linkTap: action.navigationType == .linkActivated)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        decide(navigationAction.request.url, mainFrame: navigationAction.targetFrame?.isMainFrame,
               linkTap: navigationAction.navigationType == .linkActivated)
    }

    private func decide(_ url: URL?, mainFrame: Bool?, linkTap: Bool) -> WKNavigationActionPolicy {
        guard let url else { return .cancel }
        switch Self.decision(for: url, home: home, reach: reach, frames: frames, mainFrame: mainFrame, linkTap: linkTap) {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .openOutside:
            openOutside?(url)
            return .cancel
        }
    }

    /// Hands `window.open` (the web client opens links in a new tab) to `openOutside` as well. A web view here has no
    /// tabs, so WebKit drops it without asking this limit, and such links did nothing.
    func catchesWindowOpen(in configuration: inout WebPage.Configuration) {
        configuration.userContentController.addUserScript(WKUserScript(source: """
            window.open = (url) => {
                if (url) window.webkit.messageHandlers.windowOpen.postMessage(new URL(url, location.href).href);
                return null;
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(WindowOpenHandler { [weak self] url in self?.openOutside?(url) }, name: "windowOpen")
    }

    /// `mainFrame` is nil for a new window.
    nonisolated static func decision(for url: URL, home: URL, reach: Reach, frames: Bool, mainFrame: Bool?, linkTap: Bool) -> Decision {
        guard let mainFrame else { return .openOutside }
        if !mainFrame { return frames ? .allow : .cancel }
        let within = switch reach {
        case .page: samePage(url, home)
        case .origin: sameOrigin(url, home)
        case .web: ["http", "https"].contains(url.scheme?.lowercased())
        }
        if within { return .allow }
        return linkTap ? .openOutside : .cancel
    }

    nonisolated static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        Origin(a) == Origin(b)
    }

    /// The same page, whatever its fragment (an anchor on it).
    nonisolated static func samePage(_ a: URL, _ b: URL) -> Bool {
        func path(_ url: URL) -> String { url.path().isEmpty ? "/" : url.path() }
        return sameOrigin(a, b) && path(a) == path(b) && a.query() == b.query()
    }
}

/// Receives the address of a `window.open` in the main frame (`WebNavigationLimit.catchesWindowOpen`).
private final class WindowOpenHandler: NSObject, WKScriptMessageHandler {
    private let open: (URL) -> Void

    init(open: @escaping (URL) -> Void) {
        self.open = open
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let text = message.body as? String, let url = URL(string: text) else { return }
        open(url)
    }
}
