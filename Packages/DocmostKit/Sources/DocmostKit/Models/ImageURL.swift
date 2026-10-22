import Foundation

/// Image URLs for avatars and space/workspace logos (`/api/attachments/img/<kind>/<file>`, no sign-in needed).
/// A stored value that starts with `http` is used as is.
public enum ImageKind: String, Sendable {
    case avatar
    case spaceIcon = "space-icon"
    case workspaceIcon = "workspace-icon"
}

public enum ImageURL {
    public static func resolve(_ value: String?, kind: ImageKind, baseURL: URL) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return URL(string: value)
        }
        return baseURL.appending(path: "api/attachments/img/\(kind.rawValue)/\(value)")
    }

    /// Media from page content (`/api/files/<id>/<name>`); legacy `/files/…` paths get an `/api` prefix.
    public static func resolveContentMedia(_ src: String?, baseURL: URL) -> URL? {
        guard let src, !src.isEmpty else { return nil }
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            return URL(string: src)
        }
        var path = src
        if path.hasPrefix("/files/") {
            path = "/api" + path
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}
