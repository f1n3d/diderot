import Foundation

/// Maps links in page content to a destination, like the web client (`apps/client/src/lib/constants.ts`,
/// `utils.tsx`). Page URLs: `/s/<space>/p/<slug>-<slugId>`, `/p/<slug>`, `/share/<key>/p/<slug>`,
/// `/docs/<space>/<slug>`.
nonisolated enum ContentLinkRouter {
    static let internalScheme = "docmost-internal"
    /// The app's own links (pages, comments, atoms) and deep links. Page content never links to them: tapped, they open a
    /// comment, another block's atom sheet with "Remove", or switch to another saved server (code review R13).
    static let appSchemes: Set<String> = [internalScheme, CommentLink.scheme, AtomLink.scheme, DeepLink.scheme]

    enum Destination: Equatable {
        case page(slugId: String, anchor: String?)
        /// A database entry (the web's `?row=…&rowBase=…`): the database page and the row to open there.
        case databaseEntry(basePageId: String, rowId: String)
        /// A comment on a page (Docmost 0.97's `?commentId=…`): the page, with the comment shown.
        case comment(slugId: String, commentId: String)
        case anchor(String)
        case user(id: String)
        case external(URL)
    }

    /// Turns an `href` from the document into a URL that `OpenURLAction` understands.
    static func url(for href: String, baseURL: URL?) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") {
            return URL(string: "\(internalScheme)://anchor/\(pathComponent(trimmed.dropFirst()))")
        }
        if trimmed.hasPrefix("/"), let baseURL {
            return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }
        if let url = URL(string: trimmed), let scheme = url.scheme {
            return appSchemes.contains(scheme.lowercased()) ? nil : url
        }
        // No scheme, e.g. `example.com/path`.
        return URL(string: "https://" + trimmed)
    }

    /// `text` as one path component, "/" encoded too: `destination` reads the last one, decoded.
    private static func pathComponent(_ text: some StringProtocol) -> String {
        text.addingPercentEncoding(withAllowedCharacters: urlPathComponentAllowed) ?? ""
    }

    private static let urlPathComponentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// Link-sheet input cleaned up like the web's `normalizeUrl` (`utils.tsx`): adds `https://` unless it has a scheme
    /// or starts with `/` or `#` (an anchor link the sheet was opened on). Nil when empty or containing spaces.
    static func normalizedLink(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let keep = trimmed.hasPrefix("/") || trimmed.hasPrefix("#") || trimmed.contains(/^[a-zA-Z][a-zA-Z0-9+.-]*:/)
        return URL(string: keep ? trimmed : "https://" + trimmed)
    }

    /// Schemes the web editor links (TipTap's `isAllowedUri`); a relative link has none. Not scripts, data or other
    /// apps.
    static func isLinkable(_ url: URL) -> Bool {
        url.scheme.map { ["http", "https", "ftp", "ftps", "mailto", "tel", "callto", "sms", "cid", "xmpp"].contains($0.lowercased()) } ?? true
    }

    /// How a link that leaves the app opens: as the web client in a browser opens it.
    enum Opening: Equatable {
        /// A web page: in the in-app browser.
        case browser
        /// Mail, phone, messages: the system shows its own sheet before anything happens.
        case system
        /// Another app: only after asking, as the browser asks.
        case askFirst
        /// Scripts, data, files (the web's `sanitizeUrl` drops the first ones) and the app's own schemes.
        case never
    }

    static func opening(for url: URL) -> Opening {
        switch url.scheme?.lowercased() {
        case "http", "https": .browser
        case "mailto", "tel", "sms": .system
        case nil, "javascript", "data", "vbscript", "file": .never
        case let scheme? where appSchemes.contains(scheme): .never
        default: .askFirst
        }
    }

    /// Ids from the page, encoded: a "/", "?" or "#" in one cut it short or became the query or anchor, and another page
    /// or user opened (code review R33).
    static func pageURL(slugId: String, anchor: String? = nil) -> URL {
        var text = "\(internalScheme)://page/\(pathComponent(slugId))"
        if let anchor, !anchor.isEmpty {
            text += "#\(anchor.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")"
        }
        return URL(string: text)!
    }

    static func userURL(id: String) -> URL {
        URL(string: "\(internalScheme)://user/\(pathComponent(id))")!
    }

    /// Web client URL `/p/<slugId>` (a page UUID works too); `destination(for:serverURL:)` maps it back to `.page`.
    static func webPageURL(server: URL, slugId: String) -> URL {
        server.appending(path: "p/\(slugId)")
    }

    /// A comment's link as the web copies it: the page with `?commentId=…`.
    static func commentWebURL(server: URL, slugId: String, commentId: String) -> URL {
        webPageURL(server: server, slugId: slugId).appending(queryItems: [URLQueryItem(name: "commentId", value: commentId)])
    }

    static func destination(for url: URL, serverURL: URL?) -> Destination {
        if url.scheme == internalScheme {
            let id = url.lastPathComponent
            switch url.host() {
            case "page": return .page(slugId: id, anchor: url.fragment(percentEncoded: false))
            case "anchor": return .anchor(id.removingPercentEncoding ?? id)
            case "user": return .user(id: id)
            default: return .external(url)
            }
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .external(url)
        }
        if let serverURL, let host = url.host()?.lowercased(), let serverHost = serverURL.host()?.lowercased(),
           host == serverHost, (url.port ?? defaultPort(scheme)) == (serverURL.port ?? defaultPort(serverURL.scheme ?? "https")),
           let slugId = pageSlugId(in: url.path())
        {
            // The entry's database: the linked page, or the database embedded in it.
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let row = query.first(where: { $0.name == "row" })?.value, !row.isEmpty,
               let base = query.first(where: { $0.name == "rowBase" })?.value, !base.isEmpty
            {
                return .databaseEntry(basePageId: base, rowId: row)
            }
            if let commentId = query.first(where: { $0.name == "commentId" })?.value, !commentId.isEmpty {
                return .comment(slugId: slugId, commentId: commentId)
            }
            return .page(slugId: slugId, anchor: url.fragment(percentEncoded: false))
        }
        return .external(url)
    }

    /// slugId from a page path: a UUID, or the part after the slug's last `-`.
    static func pageSlugId(in path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let slug = pageSlug(parts: parts) else { return nil }
        if UUID(uuidString: slug) != nil {
            return slug
        }
        if let dash = slug.lastIndex(of: "-") {
            let slugId = String(slug[slug.index(after: dash)...])
            return slugId.isEmpty ? nil : slugId
        }
        return slug.isEmpty ? nil : slug
    }

    private static func pageSlug(parts: [String]) -> String? {
        if let index = parts.lastIndex(of: "p"), index + 1 < parts.count {
            return parts[index + 1]
        }
        if parts.first == "docs", parts.count >= 3 {
            return parts[2]
        }
        return nil
    }

    private static func defaultPort(_ scheme: String) -> Int {
        scheme == "http" ? 80 : 443
    }
}
