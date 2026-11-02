import Foundation
import Observation

/// External deep links (`diderot://open?url=…`, pasted web URLs). `MainTabView` consumes `pendingSelection`.
@MainActor
@Observable
final class AppNavigation {
    var pendingSelection: PageSelection?

    /// Returns `false` if the URL is not a Docmost page on the configured server.
    @discardableResult
    func open(_ url: URL, serverURL: URL?) -> Bool {
        guard let selection = Self.selection(for: url, serverURL: serverURL) else { return false }
        pendingSelection = selection
        return true
    }

    /// Opens a page of the current server, or switches to the saved server it is on and opens it there; else `false`.
    func handle(_ url: URL, session: AppSession) -> Bool {
        if open(url, serverURL: session.server?.url) { return true }
        guard let webURL = DeepLink.webURL(from: url), let account = session.account(matching: webURL),
              let selection = Self.selection(for: url, serverURL: account.serverURL)
        else { return false }
        Task {
            await session.switchTo(account)
            pendingSelection = selection
        }
        return true
    }

    private static func selection(for url: URL, serverURL: URL?) -> PageSelection? {
        switch DeepLink.resolve(url, serverURL: serverURL) {
        case .page(let slugId, _): PageSelection(pageId: slugId)
        case .databaseEntry(let basePageId, let rowId): PageSelection(pageId: basePageId, rowId: rowId)
        case .comment(let slugId, let commentId): PageSelection(pageId: slugId, commentId: commentId)
        default: nil
        }
    }
}

nonisolated enum DeepLink {
    static let scheme = "diderot"

    /// Unwraps `diderot://open?url=<web-url>`; http(s) URLs pass through unchanged.
    static func webURL(from url: URL) -> URL? {
        if url.scheme?.lowercased() == scheme {
            guard url.host()?.lowercased() == "open",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let target = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let webURL = URL(string: target)
            else { return nil }
            return webURL
        }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        return nil
    }

    static func resolve(_ url: URL, serverURL: URL?) -> ContentLinkRouter.Destination {
        guard let webURL = webURL(from: url) else { return .external(url) }
        return ContentLinkRouter.destination(for: webURL, serverURL: serverURL)
    }
}
