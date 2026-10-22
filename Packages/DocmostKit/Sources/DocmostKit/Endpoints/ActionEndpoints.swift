import Foundation

/// The web client's page actions: duplicate, move/copy to another space, export.
extension Endpoints.Pages {
    public struct DuplicateBody: Encodable, Sendable {
        public let pageId: String
        public let spaceId: String?
    }

    /// Duplicates a page in the same space (no `spaceId`) or copies it to another space.
    public static func duplicate(pageId: String, spaceId: String? = nil) -> Endpoint<Page> {
        .post("pages/duplicate", body: DuplicateBody(pageId: pageId, spaceId: spaceId))
    }

    public struct MoveToSpaceBody: Encodable, Sendable {
        public let pageId: String
        public let spaceId: String
    }

    /// Moves a page and its subpages to another space (the server rejects the same space with 400).
    public static func moveToSpace(pageId: String, spaceId: String) -> Endpoint<NoContent> {
        .post("pages/move-to-space", body: MoveToSpaceBody(pageId: pageId, spaceId: spaceId))
    }

    public enum ExportFormat: String, Encodable, Sendable {
        case markdown
        case html

        public var fileExtension: String { self == .markdown ? "md" : "html" }
    }

    public struct ExportBody: Encodable, Sendable {
        public let pageId: String
        public let format: ExportFormat
        public let includeChildren: Bool
        public let includeAttachments: Bool
    }

    /// File or ZIP (subpages/attachments) without envelope, named in `Content-Disposition`; use `APIClient.sendRaw`.
    public static func export(pageId: String, format: ExportFormat, includeChildren: Bool = false, includeAttachments: Bool = false) -> Endpoint<NoContent> {
        .post("pages/export", body: ExportBody(
            pageId: pageId, format: format, includeChildren: includeChildren, includeAttachments: includeAttachments
        ))
    }
}

extension Endpoints.Pages {
    public struct MoveBody: Encodable, Sendable {
        public let pageId: String
        public let position: String
        public let parentPageId: String?
    }

    /// Reorders or reparents a page; `position` is a `FractionalIndex` key.
    public static func move(pageId: String, position: String, parentPageId: String?) -> Endpoint<NoContent> {
        .post("pages/move", body: MoveBody(pageId: pageId, position: position, parentPageId: parentPageId))
    }

    public struct TrashBody: Encodable, Sendable {
        public let spaceId: String
        public let limit: Int?
        public let cursor: String?
    }

    /// Pages in a space's trash.
    public static func trash(spaceId: String, cursor: String? = nil, limit: Int = 50) -> Endpoint<Paginated<Page>> {
        .post("pages/trash", body: TrashBody(spaceId: spaceId, limit: limit, cursor: cursor))
    }
}

extension Endpoints.Workspace {
    /// Workspace members (the server checks read permission, 403 otherwise).
    public static func members(_ pagination: PaginationOptions = PaginationOptions(limit: 100)) -> Endpoint<Paginated<WorkspaceMember>> {
        .post("workspace/members", body: pagination)
    }
}

/// Filename from `Content-Disposition: attachment; filename="…"`.
public enum ContentDisposition {
    public static func filename(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        let pattern = #"filename\*?=(?:UTF-8'')?"?([^";]+)"?"#
        guard let match = header.range(of: pattern, options: .regularExpression) else { return nil }
        let raw = String(header[match]).replacingOccurrences(of: #"^filename\*?=(?:UTF-8'')?"?"#, with: "", options: .regularExpression)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).removingPercentEncoding
    }
}
